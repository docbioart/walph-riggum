#!/bin/bash

# ============================================================================
# RUNNER — Shared iteration runner for Walph and Good Bunny
# ============================================================================
#
# This library provides a unified iteration runner that handles:
# - Prompt template loading and variable substitution
# - Claude execution with timeout watchdog
# - Rate limit and API error detection
# - Circuit breaker updates
# - Completion detection
#
# Usage: Source this file and call run_shared_iteration() with appropriate
#        callbacks for tool-specific template substitution.

set -euo pipefail

# Track temp files for cleanup on exit (array: whitespace-safe paths)
RUNNER_TEMP_FILES=()

cleanup_runner_temp_files() {
    if [[ ${#RUNNER_TEMP_FILES[@]} -gt 0 ]]; then
        rm -f -- "${RUNNER_TEMP_FILES[@]}" 2>/dev/null || true
        RUNNER_TEMP_FILES=()
    fi
}

# On INT/TERM: kill the in-flight Claude child (it would otherwise keep
# running autonomously), clean up, and actually exit — a bare cleanup trap
# would let execution resume after the signal.
_runner_on_signal() {
    if [[ -n "${RUNNER_CLAUDE_PID:-}" ]]; then
        kill "$RUNNER_CLAUDE_PID" 2>/dev/null || true
    fi
    cleanup_runner_temp_files
    exit 130
}

trap cleanup_runner_temp_files EXIT
trap _runner_on_signal INT TERM

# Create a tracked temp file. Sets RUNNER_LAST_TEMP rather than echoing:
# callers using $(make_runner_temp) would run it in a subshell, and the
# registration in RUNNER_TEMP_FILES would never reach the parent (the EXIT
# trap would then clean nothing).
make_runner_temp() {
    RUNNER_LAST_TEMP=$(mktemp)
    RUNNER_TEMP_FILES+=("$RUNNER_LAST_TEMP")
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
    local timed_out="$5"
    local extra_detail="${6:-}"

    local note_file="$PROJECT_DIR/$state_dir/last_iteration_note"
    {
        echo "Iteration $iteration ($MODE mode) finished at $(date '+%H:%M:%S')."
        echo "Reported status: $status_summary"
        if [[ -n "$error_msg" ]]; then
            echo "Error observed in its output: $error_msg"
        fi
        if [[ "$timed_out" == "true" ]]; then
            echo "It hit the iteration timeout and was killed — its work may be half-finished and uncommitted. Reconcile the working tree first, and keep your task small."
        fi
        if [[ -n "$extra_detail" ]]; then
            echo "$extra_detail"
        fi
    } > "$note_file" 2>/dev/null || true
}

# Run a single iteration of the autonomous loop
#
# Parameters:
#   $1: iteration number
#   $2: prompt file path
#   $3: model name
#   $4: state directory path (for completion signal file)
#   $5: callback function name for additional template substitutions (optional)
#   $6: dry run extra info callback function name (optional)
#
# Callbacks:
#   - Template substitution callback receives $full_prompt as stdin, returns modified prompt
#   - Dry run info callback is called to print additional dry run information
#
# Returns:
#   0: success
#   1: error
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

    # Build the prompt
    local full_prompt=""

    # Add prompt template
    if [[ -f "$prompt_file" ]]; then
        full_prompt=$(cat "$prompt_file")
    else
        log_error "Prompt file not found: $prompt_file"
        return 1
    fi

    # Substitute common variables in prompt using bash parameter expansion
    # This is safer and more efficient than sed
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
            log_warn "Principles file not found: $principles_file"
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

    # Apply tool-specific template substitutions via callback
    if [[ -n "$template_callback" ]] && declare -f "$template_callback" > /dev/null 2>&1; then
        full_prompt=$("$template_callback" "$full_prompt")
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run Claude with:"
        echo "  Model: $model"
        echo "  Prompt file: $prompt_file"
        echo "  Mode: $MODE"

        # Call dry run info callback for tool-specific info
        if [[ -n "$dryrun_callback" ]] && declare -f "$dryrun_callback" > /dev/null 2>&1; then
            "$dryrun_callback"
        fi

        return 0
    fi

    # Run Claude
    local timeout="${ITERATION_TIMEOUT:-900}"
    log_info "Running Claude ($model)... (timeout: ${timeout}s)"

    # Snapshot the plan's checked-off tasks so that if this iteration is
    # killed by the timeout, any boxes it checked can be flagged as
    # unverified for the next iteration to re-verify.
    local pre_checked=""
    if [[ -n "${COMPLETION_GROUND_TRUTH:-}" ]] && [[ -f "${COMPLETION_GROUND_TRUTH:-}" ]]; then
        pre_checked=$(grep -E '^[[:space:]]*- \[x\]' "$COMPLETION_GROUND_TRUTH" 2>/dev/null || true)
    fi

    local output
    local exit_code=0

    # Create temp files for prompt input and output capture
    local temp_prompt temp_output temp_err
    make_runner_temp; temp_prompt="$RUNNER_LAST_TEMP"
    printf '%s' "$full_prompt" > "$temp_prompt"

    make_runner_temp; temp_output="$RUNNER_LAST_TEMP"
    make_runner_temp; temp_err="$RUNNER_LAST_TEMP"

    # Build fast mode flag if enabled
    local fast_settings=""
    if [[ "${FAST_MODE:-false}" == "true" ]]; then
        fast_settings='--settings {"fastMode":true}'
    fi

    # With jq available, run in JSON output mode so we can capture per-iteration
    # cost and a clean result payload. Without jq we can't parse it, so keep the
    # legacy text mode (status block parsing depends on unescaped newlines).
    local json_mode=false
    if command -v jq &>/dev/null; then
        json_mode=true
    fi

    local iteration_start_ts
    iteration_start_ts=$(date +%s)

    # Run Claude in the background with a timeout watchdog.
    # Using a temp file for input (not pipe) ensures clean EOF delivery.
    # The background PID lets us kill it if it exceeds the timeout.
    if [[ "$json_mode" == "true" ]]; then
        claude -p \
            --dangerously-skip-permissions \
            --model "$model" \
            --output-format json \
            ${fast_settings} \
            < "$temp_prompt" \
            > "$temp_output" 2> "$temp_err" &
    else
        claude -p \
            --dangerously-skip-permissions \
            --model "$model" \
            ${fast_settings} \
            < "$temp_prompt" \
            > "$temp_output" 2>&1 &
    fi
    local claude_pid=$!
    RUNNER_CLAUDE_PID="$claude_pid"  # for the INT/TERM handler

    # Watchdog: wait up to $timeout seconds for Claude to finish
    local elapsed=0
    while kill -0 "$claude_pid" 2>/dev/null; do
        if [[ $elapsed -ge $timeout ]]; then
            log_warn "Claude has been running for ${timeout}s — killing stuck process"
            # Guard every step: the process can die between checks, and under
            # set -e an unguarded failing kill/wait aborts the whole script
            # mid-recovery (losing the handoff note and the rest of the loop)
            kill "$claude_pid" 2>/dev/null || true
            # Give it a moment to die, then force-kill
            sleep 2
            kill -9 "$claude_pid" 2>/dev/null || true
            wait "$claude_pid" 2>/dev/null || true
            exit_code=124  # Same exit code as GNU timeout
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    # If it exited on its own, collect the real exit code.
    # The || capture keeps set -e from killing the script when Claude exits
    # nonzero — a failed iteration must be handled, not fatal.
    if [[ $exit_code -ne 124 ]]; then
        if wait "$claude_pid"; then
            exit_code=0
        else
            exit_code=$?
        fi
    fi

    RUNNER_CLAUDE_PID=""
    rm -f "$temp_prompt"

    # Capture output once and display it. In JSON mode, unwrap the result text
    # and cost; fall back to raw output if the JSON is unparseable (e.g., the
    # process was killed mid-write).
    local cost_usd=""
    local raw_stdout
    raw_stdout=$(cat "$temp_output")
    rm -f "$temp_output"

    if [[ "$json_mode" == "true" ]]; then
        local raw_stderr
        raw_stderr=$(cat "$temp_err")
        if [[ -n "$raw_stdout" ]] && jq -e . >/dev/null 2>&1 <<< "$raw_stdout"; then
            output=$(jq -r '.result // empty' <<< "$raw_stdout")
            cost_usd=$(jq -r '.total_cost_usd // empty' <<< "$raw_stdout")
            if [[ -z "$output" ]]; then
                output="$raw_stdout"
            fi
        else
            output="$raw_stdout"
        fi
        # Keep stderr visible to error/rate-limit detection, as 2>&1 used to
        if [[ -n "$raw_stderr" ]]; then
            output="$output"$'\n'"$raw_stderr"
        fi
    else
        output="$raw_stdout"
    fi
    rm -f "$temp_err"
    echo "$output"

    # Handle timeout
    if [[ $exit_code -eq 124 ]]; then
        log_error "Iteration timed out after ${timeout}s"
        log_info "Claude may have stalled on an API call or long-running task"
        log_info "The next iteration will retry. Raise the limit with --timeout SECONDS (or ITERATION_TIMEOUT in config)."
    fi

    # Log the output
    log_claude_output "$output"

    # Check for rate limit
    if check_rate_limit "$output"; then
        local rate_limit_choice=0
        handle_rate_limit "$output" || rate_limit_choice=$?
        if [[ $rate_limit_choice -eq 2 ]]; then
            return 2  # Exit signal
        fi
    fi

    # Network outage: a connection-level failure is not Claude being stuck.
    # Don't count it toward the circuit breaker — pause until connectivity
    # returns, then have the main loop retry this same iteration (return 4).
    if [[ $exit_code -ne 0 ]] && check_connection_error "$output"; then
        log_warn "Claude could not reach the API (network down?) — pausing until connectivity returns"
        if wait_for_connectivity; then
            log_info "Connectivity restored — will retry iteration $iteration"
            return 4
        fi
        log_error "Still offline after the maximum wait (WALPH_OFFLINE_MAX_WAIT) — giving up on this iteration"
        return 1
    fi

    # Check for API error
    if check_api_error "$output"; then
        log_error "API error detected"
        local error_msg
        error_msg=$(extract_error_message "$output")
        if [[ -n "$error_msg" ]]; then
            log_error "$error_msg"
        fi
    fi

    # Parse status
    local status_summary
    status_summary=$(get_status_summary "$output")
    log_info "Status: $status_summary"

    # Update circuit breaker. A nonzero return means Claude signaled it is
    # stuck — persist that so run_main_loop stops, instead of letting set -e
    # abort here with the handoff note unwritten.
    local error_msg
    error_msg=$(extract_error_message "$output")
    if ! update_circuit_breaker "$output" "$error_msg"; then
        touch "$PROJECT_DIR/$state_dir/stuck_signal"
    fi

    # Leave a short handoff note for the next (fresh-context) iteration
    local timed_out=false
    [[ $exit_code -eq 124 ]] && timed_out=true

    # A killed iteration may have checked off tasks it never finished, and
    # usually leaves uncommitted work. Give the next iteration the specifics
    # so it verifies that work instead of trusting or discarding it.
    local timeout_detail=""
    if [[ "$timed_out" == "true" ]]; then
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
    _write_last_iteration_note "$state_dir" "$iteration" "$status_summary" "$error_msg" "$timed_out" "$timeout_detail"

    # Record cost/duration/outcome for this iteration
    local duration=$(( $(date +%s) - iteration_start_ts ))
    if [[ -n "$cost_usd" ]]; then
        log_info "Iteration took ${duration}s, cost \$${cost_usd}"
    fi
    if declare -f log_iteration_summary > /dev/null 2>&1; then
        log_iteration_summary "$iteration" "$MODE" "$model" "$duration" "$cost_usd" "$status_summary"
    fi

    # Check for completion. Claude's EXIT_SIGNAL is a self-report — when a
    # ground-truth file/dir is configured (e.g., IMPLEMENTATION_PLAN.md in
    # build mode), verify the checkboxes on disk agree before ending the loop.
    if check_completion "$output"; then
        local completion_blocked=false
        if [[ -n "${WALPH_RECOVERY_TASKS_FILE:-}" ]]; then
            # Recovery run: only the recovery tasks gate completion — the
            # rest of the plan is deliberately out of scope
            if declare -f has_unchecked_recovery_tasks > /dev/null 2>&1 \
                && has_unchecked_recovery_tasks "${COMPLETION_GROUND_TRUTH:-$PROJECT_DIR/IMPLEMENTATION_PLAN.md}" "$WALPH_RECOVERY_TASKS_FILE"; then
                completion_blocked=true
                log_warn "Claude signaled completion, but recovery tasks remain unchecked — ignoring the exit signal and continuing"
            fi
        elif [[ -n "${COMPLETION_GROUND_TRUTH:-}" ]] \
            && declare -f has_unchecked_boxes > /dev/null 2>&1 \
            && has_unchecked_boxes "$COMPLETION_GROUND_TRUTH"; then
            completion_blocked=true
            log_warn "Claude signaled completion, but unchecked items remain in ${COMPLETION_GROUND_TRUTH#"$PROJECT_DIR"/} — ignoring the exit signal and continuing"
        fi
        if [[ "$completion_blocked" != "true" ]]; then
            log_success "Completion signal received!"
            # Write signal file so main_loop breaks after this iteration
            touch "$PROJECT_DIR/$state_dir/completion_signal"
            return 0
        fi
    fi

    # Normalize to 0/1. Claude's raw exit code must not leak out: return
    # code 2 is reserved for the rate-limit handler's "exit and resume"
    # choice, and Claude itself exits 2 on usage errors.
    if [[ $exit_code -eq 0 ]]; then
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
#   1: error or circuit breaker triggered
run_main_loop() {
    local config_dir="$1"
    local state_dir="$2"
    local model_getter="$3"
    local tool_name="$4"

    # Global flag: distinguishes "completed" from "hit max iterations" for callers
    LOOP_COMPLETED=false

    # Clear stale signals a previous interrupted run may have left behind —
    # a leftover completion_signal would end this run after one iteration,
    # a leftover stuck_signal would abort it
    rm -f "$PROJECT_DIR/$state_dir/completion_signal" "$PROJECT_DIR/$state_dir/stuck_signal"

    local iteration=1
    local net_retry_count=0

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

        # Run iteration. The || capture keeps set -e from aborting the loop
        # on a failed iteration — failures are handled below, not fatal.
        WALPH_CURRENT_ITERATION="$iteration"
        local result=0
        run_iteration "$iteration" "$prompt_file" "$model" || result=$?

        # Network-outage retry: connectivity is back — rerun the SAME
        # iteration without burning the counter or the circuit breaker.
        # The consecutive cap guards against a reachable-but-broken API.
        if [[ $result -eq 4 ]]; then
            net_retry_count=$((net_retry_count + 1))
            if [[ $net_retry_count -le 8 ]]; then
                log_info "Retrying iteration $iteration after connectivity pause (retry $net_retry_count)"
                continue
            fi
            log_warn "Connectivity keeps failing mid-request — counting as a failed iteration"
            result=1
        else
            net_retry_count=0
        fi

        if [[ $result -eq 0 ]]; then
            log_success "Iteration $iteration completed successfully"
        elif [[ $result -eq 2 ]]; then
            log_info "Exit requested by user"
            return 0
        else
            log_warn "Iteration $iteration completed with issues"
        fi

        # Stop if the iteration recorded a stuck signal from Claude
        if [[ -f "$PROJECT_DIR/$state_dir/stuck_signal" ]]; then
            rm -f "$PROJECT_DIR/$state_dir/stuck_signal"
            log_error "Claude signaled it is stuck — stopping loop"
            log_info "Run '$tool_name reset' to clear state, then refine the specs/plan"
            return 1
        fi

        # Check for completion signal file
        if [[ -f "$PROJECT_DIR/$state_dir/completion_signal" ]]; then
            log_success "All work completed!"
            rm -f "$PROJECT_DIR/$state_dir/completion_signal"
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
