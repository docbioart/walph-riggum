#!/bin/bash

# ============================================================================
# RUNNER — Shared iteration runner for Walph and Good Bunny
# ============================================================================
#
# This library provides a unified iteration runner that handles:
# - Prompt template loading and variable substitution
# - One bounded agent invocation via the harness layer (lib/harness.sh)
# - Rate limit, network outage and API error detection on the harness's
#   error channel
# - Circuit breaker updates and the explicit stuck signal
# - Completion detection (exit code + final response + status block +
#   ground-truth checkboxes)
#
# Usage: Source this file (after lib/harness.sh) and call
#        run_shared_iteration() with appropriate callbacks for tool-specific
#        template substitution.
#
# shellcheck disable=SC2034  # LOOP_COMPLETED / WALPH_CURRENT_ITERATION are read by callers

set -euo pipefail

# Track temp files for cleanup on exit. An array, not a space-joined string:
# with a TMPDIR that contains a space, word splitting would leak the real
# files and could remove an unrelated path.
RUNNER_TEMP_FILES=()

cleanup_runner_temp_files() {
    if [[ ${#RUNNER_TEMP_FILES[@]} -gt 0 ]]; then
        rm -f -- "${RUNNER_TEMP_FILES[@]}" 2>/dev/null || true
        RUNNER_TEMP_FILES=()
    fi
    if declare -f harness_cleanup_scratch > /dev/null 2>&1; then
        harness_cleanup_scratch
    fi
}

# On Ctrl-C / TERM: stop the agent's whole process tree (it runs in its own
# process group, so the terminal's SIGINT does not reach it), clean up, exit.
_runner_on_signal() {
    echo ""
    log_warn "Interrupted — stopping the running agent"
    harness_kill_current
    cleanup_runner_temp_files
    exit 130
}

trap cleanup_runner_temp_files EXIT
trap _runner_on_signal INT TERM

# Create a tracked temp file and store its path in the named variable.
# (A $(...) capture would register the file in a subshell and lose it.)
# Usage: new_runner_temp temp_prompt
new_runner_temp() {
    local var_name="$1"
    local tmp
    tmp=$(mktemp)
    RUNNER_TEMP_FILES+=("$tmp")
    eval "$var_name=\"\$tmp\""
}

# Remove one tracked temp file now (keeps big transcripts from piling up)
release_runner_temp() {
    local file="$1"
    [[ -n "$file" ]] || return 0
    rm -f -- "$file" 2>/dev/null || true
    # rebuild without it (exact match; bash 3.2 cannot unset by value)
    local kept=() f
    for f in ${RUNNER_TEMP_FILES[@]+"${RUNNER_TEMP_FILES[@]}"}; do
        [[ "$f" == "$file" ]] || kept+=("$f")
    done
    RUNNER_TEMP_FILES=(${kept[@]+"${kept[@]}"})
}

# Remove the loop's signal files from a state directory (stale signals from an
# interrupted session must not end a new one early)
clear_loop_signals() {
    local state_dir="$1"
    rm -f "${PROJECT_DIR:?}/${state_dir:?}/completion_signal" "${PROJECT_DIR:?}/${state_dir:?}/stuck_signal"
}

# Build the {{LAST_ITERATION}} block: a short memory handoff so the fresh
# context knows what just happened and whether the loop is losing traction.
_build_last_iteration_block() {
    local state_dir="$1"
    local note_file="$PROJECT_DIR/$state_dir/last_iteration_note"
    local block="## Previous Iteration"$'\n'

    if [[ -f "$note_file" ]]; then
        block+=$'\n'"$(cat "$note_file")"
    else
        block+=$'\n'"This is the first iteration of this session — no previous iteration to report."
    fi

    # Circuit breaker counters: warn the agent when the loop is close to tripping
    if declare -f _read_state > /dev/null 2>&1 && [[ -n "${CIRCUIT_BREAKER_STATE_FILE:-}" ]] && [[ -f "${CIRCUIT_BREAKER_STATE_FILE:-}" ]]; then
        local nc se ncm
        nc=$(_read_state "no_change_count"); nc=${nc:-0}
        se=$(_read_state "same_error_count"); se=${se:-0}
        ncm=$(_read_state "no_commit_count"); ncm=${ncm:-0}
        if [[ "$nc" -ge 2 ]]; then
            block+=$'\n'"**WARNING:** $nc consecutive iteration(s) produced no file changes. The loop will auto-stop soon — make concrete progress this iteration, even if small."
        fi
        if [[ "$ncm" -ge 2 ]]; then
            block+=$'\n'"**WARNING:** $ncm consecutive iteration(s) ended without a commit. Pick something small you can finish and land it this iteration."
        fi
        if [[ "$se" -ge 2 ]]; then
            block+=$'\n'"**WARNING:** The same error has now repeated $se times. Do NOT retry the same approach — try a different one, or output the stuck signal with an explanation."
        fi
    fi

    printf '%s' "$block"
}

# Persist a short note about this iteration for the next one to read
_write_last_iteration_note() {
    local state_dir="$1"
    local iteration="$2"
    local status_summary="$3"
    local error_msg="$4"
    local outcome="$5"   # ok | timeout | exit:<code> | no-response
    local extra_detail="${6:-}"

    local note_file="$PROJECT_DIR/$state_dir/last_iteration_note"
    {
        echo "Iteration $iteration ($MODE mode) finished at $(date '+%H:%M:%S')."
        echo "Reported status: $status_summary"
        if [[ -n "$error_msg" ]]; then
            echo "Error observed in its output: $error_msg"
        fi
        case "$outcome" in
            timeout)
                echo "It hit the iteration timeout and was killed — its work may be half-finished and uncommitted. Reconcile the working tree first, and keep your task small."
                ;;
            exit:*)
                echo "The agent process exited with code ${outcome#exit:} — its work may be incomplete or uncommitted. Reconcile the working tree first."
                ;;
            no-response)
                echo "The agent produced no final response — treat its work as unverified. Reconcile the working tree first."
                ;;
        esac
        if [[ -n "$extra_detail" ]]; then
            echo "$extra_detail"
        fi
    } > "$note_file" 2>/dev/null || true
}

# Load a prompt template and apply the common substitutions
# ({{ITERATION}}, {{MAX_ITERATIONS}}, {{MODE}}, {{PRINCIPLES}}, {{LAST_ITERATION}})
# Usage: full_prompt=$(render_prompt_template <prompt_file> <iteration> <state_dir>)
render_prompt_template() {
    local prompt_file="$1"
    local iteration="$2"
    local state_dir="$3"

    local full_prompt
    full_prompt=$(cat "$prompt_file")

    # Bash parameter expansion for numeric/simple values
    full_prompt="${full_prompt//\{\{ITERATION\}\}/$iteration}"
    full_prompt="${full_prompt//\{\{MAX_ITERATIONS\}\}/$MAX_ITERATIONS}"
    full_prompt="${full_prompt//\{\{MODE\}\}/$MODE}"

    # Inject shared engineering principles (single source of truth for rules
    # that used to be duplicated across every prompt template)
    if [[ "$full_prompt" == *"{{PRINCIPLES}}"* ]]; then
        local principles_file="${PRINCIPLES_FILE:-$SCRIPT_DIR/templates/PRINCIPLES.md}"
        local principles=""
        if [[ -f "$principles_file" ]]; then
            principles=$(cat "$principles_file")
        else
            log_warn "Principles file not found: $principles_file" >&2
        fi
        full_prompt=$(substitute_placeholder "$full_prompt" "{{PRINCIPLES}}" "$principles")
    fi

    # Inject a short memory of the previous iteration (fresh contexts repeat
    # mistakes without it)
    if [[ "$full_prompt" == *"{{LAST_ITERATION}}"* ]]; then
        local last_iter_block
        last_iter_block=$(_build_last_iteration_block "$state_dir")
        full_prompt=$(substitute_placeholder "$full_prompt" "{{LAST_ITERATION}}" "$last_iter_block")
    fi

    printf '%s' "$full_prompt"
}

# Run a single iteration of the autonomous loop
#
# Parameters:
#   $1: iteration number
#   $2: prompt file path
#   $3: model name (empty = harness default)
#   $4: state directory path (for completion/stuck signal files)
#   $5: callback function name for additional template substitutions (optional)
#   $6: dry run extra info callback function name (optional)
#
# Returns (the agent's raw exit code never leaks out: 2 and 4 mean something
# to run_main_loop, and agent CLIs use those codes too):
#   0: success
#   1: error — nonzero agent exit, timeout, or an explicit stuck signal
#   2: user requested exit (from rate limit handler)
#   4: network outage — connectivity has returned; retry the same iteration
run_shared_iteration() {
    local iteration="$1"
    local prompt_file="$2"
    local model="$3"
    local state_dir="$4"
    local template_callback="${5:-}"
    local dryrun_callback="${6:-}"

    log_iteration_start "$iteration" "$MAX_ITERATIONS" "$MODE"

    if [[ ! -f "$prompt_file" ]]; then
        log_error "Prompt file not found: $prompt_file"
        return 1
    fi

    local full_prompt
    full_prompt=$(render_prompt_template "$prompt_file" "$iteration" "$state_dir")

    # Apply tool-specific template substitutions via callback
    if [[ -n "$template_callback" ]] && declare -f "$template_callback" > /dev/null 2>&1; then
        full_prompt=$("$template_callback" "$full_prompt")
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        harness_build_cmd "$model" full "<final-message-file>" || return 1
        log_info "[DRY RUN] Would run $(harness_display_name) with:"
        echo "  Harness: $HARNESS"
        echo "  Model: ${model:-<harness default>}"
        echo "  Prompt file: $prompt_file"
        echo "  Mode: $MODE"
        echo "  Command: $(harness_cmd_string) < <prompt>"

        # Call dry run info callback for tool-specific info
        if [[ -n "$dryrun_callback" ]] && declare -f "$dryrun_callback" > /dev/null 2>&1; then
            "$dryrun_callback"
        fi

        return 0
    fi

    local timeout="${ITERATION_TIMEOUT:-900}"
    log_info "Running $(harness_display_name) (${model:-harness default})... (timeout: ${timeout}s)"

    # Snapshot the plan's checked-off tasks so that if this iteration is
    # killed by the timeout, any boxes it checked can be flagged as
    # unverified for the next iteration (and for 'walph recover').
    local pre_checked=""
    if [[ -n "${COMPLETION_GROUND_TRUTH:-}" ]] && [[ -f "${COMPLETION_GROUND_TRUTH:-}" ]]; then
        pre_checked=$(grep -E '^[[:space:]]*- \[x\]' "$COMPLETION_GROUND_TRUTH" 2>/dev/null || true)
    fi

    local temp_prompt temp_output temp_err temp_final
    new_runner_temp temp_prompt
    new_runner_temp temp_output
    new_runner_temp temp_err
    new_runner_temp temp_final
    printf '%s' "$full_prompt" > "$temp_prompt"

    local iteration_start_ts
    iteration_start_ts=$(date +%s)

    local exit_code=0
    harness_exec "$model" full "$temp_prompt" "$temp_output" "$temp_err" "$temp_final" "$timeout" || exit_code=$?
    harness_parse_result "$temp_output" "$temp_err" "$temp_final"
    # The loop only reads the END of the response (status block, signals), so
    # cap it here. Callers that need the whole text (Jeeroy's generated specs,
    # plan review) parse the result themselves and are not capped.
    harness_cap_text

    # Console shows the final response (the control channel); the raw event
    # stream and stderr go to the session log only
    if [[ "$HARNESS_TEXT_OK" == "true" ]]; then
        printf '%s\n' "$HARNESS_TEXT"
    else
        log_warn "No final response from $(harness_display_name) (exit code $exit_code). Last output lines:"
        tail -20 "$temp_output" 2>/dev/null | sed 's/^/  /'
    fi
    log_harness_transcript "$temp_output" "$temp_err"

    release_runner_temp "$temp_prompt"
    release_runner_temp "$temp_output"
    release_runner_temp "$temp_err"
    release_runner_temp "$temp_final"

    # Outcome classification
    local outcome="ok"
    if [[ $exit_code -eq 124 ]]; then
        outcome="timeout"
        log_error "Iteration timed out after ${timeout}s"
        log_info "The agent may have stalled on an API call or long-running task"
        log_info "The next iteration will retry. Raise the limit with --timeout SECONDS (or ITERATION_TIMEOUT in config)."
    elif [[ $exit_code -ne 0 ]]; then
        outcome="exit:$exit_code"
        log_error "$(harness_display_name) exited with code $exit_code"
    elif [[ "$HARNESS_TEXT_OK" != "true" ]]; then
        outcome="no-response"
    fi
    if [[ -n "$HARNESS_ERRORS" ]]; then
        local err_line
        while IFS= read -r err_line; do
            log_error "$err_line"
        done < <(printf '%s\n' "$HARNESS_ERRORS" | head -3)
    fi
    if [[ "$HARNESS_MALFORMED_LINES" -gt 0 ]]; then
        log_debug "$HARNESS_MALFORMED_LINES unparseable line(s) in the harness output stream"
    fi

    # Rate limit (structured error channel only — never the agent's prose)
    if check_rate_limit "$HARNESS_ERRORS"; then
        local rate_limit_choice=0
        handle_rate_limit "$HARNESS_ERRORS" || rate_limit_choice=$?
        if [[ $rate_limit_choice -eq 2 ]]; then
            return 2  # Exit signal
        fi
    fi

    # Network outage: a connection-level failure is not the agent being stuck.
    # Don't count it toward the circuit breaker — pause until connectivity
    # returns, then have the main loop retry this same iteration (return 4).
    #
    # Only for an agent that EXITED on the failure. One that was killed by the
    # timeout is handled as a timeout, so the tasks it checked off are recorded
    # as unverified. And when the retries are used up, or the wait runs out,
    # fall through to the normal failure bookkeeping below (handoff note,
    # circuit breaker) instead of returning early without it.
    if [[ "$outcome" == exit:* ]] && check_connection_error "$HARNESS_ERRORS"; then
        if [[ "${RUNNER_NET_RETRY_COUNT:-0}" -ge "${RUNNER_NET_RETRY_MAX:-8}" ]]; then
            log_warn "Connectivity keeps failing mid-request — counting this as a failed iteration"
        else
            log_warn "$(harness_display_name) could not reach the API (network down?) — pausing until connectivity returns"
            if wait_for_connectivity; then
                log_info "Connectivity restored — will retry iteration $iteration"
                _write_last_iteration_note "$state_dir" "$iteration" "no status (network outage)" \
                    "$(extract_error_message "$HARNESS_ERRORS")" "$outcome" \
                    "The network dropped during this iteration; it is being retried. Reconcile the working tree first."
                return 4
            fi
            log_error "Still offline after the maximum wait (WALPH_OFFLINE_MAX_WAIT) — counting this as a failed iteration"
        fi
    fi

    if check_api_error "$HARNESS_ERRORS"; then
        log_error "API error detected"
    fi

    # Parse status from the final response
    local status_summary
    status_summary=$(get_status_summary "$HARNESS_TEXT")
    log_info "Status: $status_summary"

    # Update circuit breaker (returns 1 on an explicit stuck signal)
    local error_msg
    error_msg=$(extract_error_message "$HARNESS_ERRORS")
    local stuck=false
    if ! update_circuit_breaker "$HARNESS_TEXT" "$error_msg"; then
        stuck=true
    fi

    # A killed iteration may have checked off tasks it never finished, and
    # usually leaves uncommitted work. Give the next iteration the specifics
    # so it verifies that work instead of trusting or discarding it.
    local timeout_detail=""
    if [[ "$outcome" == "timeout" ]]; then
        if [[ -n "${COMPLETION_GROUND_TRUTH:-}" ]] && [[ -f "${COMPLETION_GROUND_TRUTH:-}" ]]; then
            local post_checked newly_checked
            post_checked=$(grep -E '^[[:space:]]*- \[x\]' "$COMPLETION_GROUND_TRUTH" 2>/dev/null || true)
            newly_checked=$(comm -13 <(printf '%s\n' "$pre_checked" | sort) <(printf '%s\n' "$post_checked" | sort) 2>/dev/null || true)
            if [[ -n "$newly_checked" ]]; then
                timeout_detail+="Tasks checked off DURING the killed iteration — treat as UNVERIFIED. Re-run each one's 'Done when' criterion; uncheck any that fail before starting new work:"$'\n'"$newly_checked"$'\n'
                # Persist for 'walph recover': plain task text, deduplicated,
                # accumulated across timeouts until recovered or completed
                local rec_file="$PROJECT_DIR/$state_dir/unverified_tasks"
                {
                    [[ -f "$rec_file" ]] && cat "$rec_file"
                    printf '%s\n' "$newly_checked" | sed -E 's/^[[:space:]]*- \[x\] //'
                } | awk 'NF && !seen[$0]++' > "${rec_file}.tmp" && mv "${rec_file}.tmp" "$rec_file"
            fi
        fi
        local dirty_files
        dirty_files=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | head -10 || true)
        if [[ -n "$dirty_files" ]]; then
            timeout_detail+="Uncommitted changes left in the working tree:"$'\n'"$dirty_files"
        fi
    fi

    # Leave a short handoff note for the next (fresh-context) iteration
    _write_last_iteration_note "$state_dir" "$iteration" "$status_summary" "$error_msg" "$outcome" "$timeout_detail"

    # Record cost/duration/outcome for this iteration
    local duration=$(( $(date +%s) - iteration_start_ts ))
    log_info "Iteration took ${duration}s, $(harness_usage_summary)"
    if declare -f log_iteration_summary > /dev/null 2>&1; then
        log_iteration_summary "$iteration" "$MODE" "$model" "$duration" "$HARNESS_COST_USD" "$status_summary" \
            "$HARNESS" "$HARNESS_TOKENS_IN" "$HARNESS_TOKENS_OUT" "$HARNESS_USAGE_COMPLETE"
    fi

    if [[ "$stuck" == "true" ]]; then
        touch "$PROJECT_DIR/$state_dir/stuck_signal"
        return 1
    fi

    # Completion. The agent's EXIT_SIGNAL is a self-report: it only counts
    # when the process exited cleanly with a real final response, and — when
    # a ground-truth file/dir is configured (e.g., IMPLEMENTATION_PLAN.md in
    # build mode) — when the checkboxes on disk agree.
    if check_completion "$HARNESS_TEXT"; then
        if [[ "$outcome" != "ok" ]]; then
            log_warn "Completion signal ignored: iteration outcome was '$outcome'"
        elif [[ -n "${WALPH_RECOVERY_TASKS_FILE:-}" ]]; then
            # Recovery run: only the recovery tasks gate completion — the
            # rest of the plan is deliberately out of scope
            if declare -f has_unchecked_recovery_tasks > /dev/null 2>&1 \
                && has_unchecked_recovery_tasks "${COMPLETION_GROUND_TRUTH:-$PROJECT_DIR/IMPLEMENTATION_PLAN.md}" "$WALPH_RECOVERY_TASKS_FILE"; then
                log_warn "Agent signaled completion, but recovery tasks remain unchecked — ignoring the exit signal and continuing"
            else
                log_success "Completion signal received!"
                touch "$PROJECT_DIR/$state_dir/completion_signal"
                return 0
            fi
        elif [[ -n "${COMPLETION_GROUND_TRUTH:-}" ]] \
            && declare -f has_unchecked_boxes > /dev/null 2>&1 \
            && has_unchecked_boxes "$COMPLETION_GROUND_TRUTH"; then
            log_warn "Agent signaled completion, but unchecked items remain in ${COMPLETION_GROUND_TRUTH#"$PROJECT_DIR"/} — ignoring the exit signal and continuing"
        else
            log_success "Completion signal received!"
            # Write signal file so main_loop breaks after this iteration
            touch "$PROJECT_DIR/$state_dir/completion_signal"
            return 0
        fi
    fi

    # Normalize to 0/1. The agent's raw exit code must not leak out: 2 is
    # reserved for the rate-limit handler's "exit and resume" choice and 4
    # for the network retry, and agent CLIs exit with those codes themselves
    # (Claude Code exits 2 on a usage error).
    if [[ "$outcome" == "ok" ]] || [[ "$outcome" == "no-response" ]]; then
        return 0
    fi
    return 1
}

# Run the main autonomous loop
#
# Parameters:
#   $1: tool config directory (e.g., ".walph" or "$GB_DIR")
#   $2: state directory path relative to project (e.g., ".walph/state" or "$GB_STATE_DIR")
#   $3: model getter function name (e.g., "get_model_for_mode" or "get_gb_model")
#   $4: tool name for error messages (e.g., "walph" or "goodbunny")
#
# Returns:
#   0: success or max iterations reached
#   1: error, circuit breaker triggered, or explicit stuck signal
run_main_loop() {
    local config_dir="$1"
    local state_dir="$2"
    local model_getter="$3"
    local tool_name="$4"

    # Global flag: distinguishes "completed" from "hit max iterations" for callers
    LOOP_COMPLETED=false

    clear_loop_signals "$state_dir"

    local iteration=1
    # read by run_shared_iteration: once the retries are used up it stops
    # returning 4 and books the failure normally
    RUNNER_NET_RETRY_COUNT=0

    while [[ $iteration -le $MAX_ITERATIONS ]]; do
        # Check circuit breaker before iteration
        if circuit_breaker_triggered; then
            log_error "Circuit breaker triggered — stopping loop"
            log_info "Run '$tool_name reset' to clear the circuit breaker"
            return 1
        fi

        # Select prompt file
        local prompt_file
        if [[ -f "$PROJECT_DIR/$config_dir/PROMPT_${MODE}.md" ]]; then
            prompt_file="$PROJECT_DIR/$config_dir/PROMPT_${MODE}.md"
        elif [[ -f "$SCRIPT_DIR/templates/PROMPT_${MODE}.md" ]]; then
            prompt_file="$SCRIPT_DIR/templates/PROMPT_${MODE}.md"
        else
            log_error "No prompt template found for mode: $MODE"
            return 1
        fi

        # Select model
        local model
        if [[ -n "$MODEL_OVERRIDE" ]]; then
            model="$MODEL_OVERRIDE"
        else
            model=$("$model_getter" "$MODE")
        fi

        # Export mode for circuit breaker (used by goodbunny)
        export TOOL_MODE="$MODE"

        # Run iteration (capture the status without tripping errexit)
        WALPH_CURRENT_ITERATION="$iteration"
        local result=0
        run_iteration "$iteration" "$prompt_file" "$model" || result=$?

        # Network-outage retry: connectivity is back — rerun the SAME
        # iteration without burning the counter or the circuit breaker.
        # The consecutive cap guards against a reachable-but-broken API.
        if [[ $result -eq 4 ]]; then
            RUNNER_NET_RETRY_COUNT=$((RUNNER_NET_RETRY_COUNT + 1))
            log_info "Retrying iteration $iteration after connectivity pause (retry $RUNNER_NET_RETRY_COUNT)"
            continue
        fi
        RUNNER_NET_RETRY_COUNT=0

        if [[ $result -eq 0 ]]; then
            log_success "Iteration $iteration completed successfully"
        elif [[ $result -eq 2 ]]; then
            log_info "Exit requested by user"
            return 0
        else
            log_warn "Iteration $iteration completed with issues"
        fi

        # Explicit stuck signal from the agent
        if [[ -f "$PROJECT_DIR/$state_dir/stuck_signal" ]]; then
            clear_loop_signals "$state_dir"
            log_error "The agent signaled it is stuck — stopping loop (see its explanation above)"
            log_info "Run '$tool_name reset' to clear state, then refine the specs/plan"
            return 1
        fi

        # Check for completion signal file
        if [[ -f "$PROJECT_DIR/$state_dir/completion_signal" ]]; then
            log_success "All work completed!"
            clear_loop_signals "$state_dir"
            LOOP_COMPLETED=true
            return 0
        fi

        ((iteration++))

        # Small delay between iterations
        sleep 1
    done

    log_warn "Maximum iterations ($MAX_ITERATIONS) reached"
    return 0
}
