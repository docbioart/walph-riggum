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

# Track temp files for cleanup on exit
RUNNER_TEMP_FILES=""

cleanup_runner_temp_files() {
    if [[ -n "$RUNNER_TEMP_FILES" ]]; then
        for f in $RUNNER_TEMP_FILES; do
            rm -f "$f" 2>/dev/null
        done
        RUNNER_TEMP_FILES=""
    fi
}

trap cleanup_runner_temp_files EXIT INT TERM

# Create a tracked temp file
make_runner_temp() {
    local tmp
    tmp=$(mktemp)
    RUNNER_TEMP_FILES="$RUNNER_TEMP_FILES $tmp"
    echo "$tmp"
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

    local output
    local exit_code=0

    # Create temp files for prompt input and output capture
    local temp_prompt
    temp_prompt=$(make_runner_temp)
    printf '%s' "$full_prompt" > "$temp_prompt"

    local temp_output
    temp_output=$(make_runner_temp)
    local temp_err
    temp_err=$(make_runner_temp)

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

    # Watchdog: wait up to $timeout seconds for Claude to finish
    local elapsed=0
    while kill -0 "$claude_pid" 2>/dev/null; do
        if [[ $elapsed -ge $timeout ]]; then
            log_warn "Claude has been running for ${timeout}s — killing stuck process"
            kill "$claude_pid" 2>/dev/null
            # Give it a moment to die, then force-kill
            sleep 2
            kill -9 "$claude_pid" 2>/dev/null
            wait "$claude_pid" 2>/dev/null
            exit_code=124  # Same exit code as GNU timeout
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    # If it exited on its own, collect the real exit code
    if [[ $exit_code -ne 124 ]]; then
        wait "$claude_pid"
        exit_code=$?
    fi

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
        log_info "The next iteration will retry. Adjust ITERATION_TIMEOUT in config if needed."
    fi

    # Log the output
    log_claude_output "$output"

    # Check for rate limit
    if check_rate_limit "$output"; then
        handle_rate_limit "$output"
        local rate_limit_choice=$?
        if [[ $rate_limit_choice -eq 2 ]]; then
            return 2  # Exit signal
        fi
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

    # Update circuit breaker
    local error_msg
    error_msg=$(extract_error_message "$output")
    update_circuit_breaker "$output" "$error_msg"

    # Leave a short handoff note for the next (fresh-context) iteration
    local timed_out=false
    [[ $exit_code -eq 124 ]] && timed_out=true
    _write_last_iteration_note "$state_dir" "$iteration" "$status_summary" "$error_msg" "$timed_out"

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
        if [[ -n "${COMPLETION_GROUND_TRUTH:-}" ]] \
            && declare -f has_unchecked_boxes > /dev/null 2>&1 \
            && has_unchecked_boxes "$COMPLETION_GROUND_TRUTH"; then
            log_warn "Claude signaled completion, but unchecked items remain in ${COMPLETION_GROUND_TRUTH#"$PROJECT_DIR"/} — ignoring the exit signal and continuing"
        else
            log_success "Completion signal received!"
            # Write signal file so main_loop breaks after this iteration
            touch "$PROJECT_DIR/$state_dir/completion_signal"
            return 0
        fi
    fi

    return "$exit_code"
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

    local iteration=1

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

        # Run iteration
        WALPH_CURRENT_ITERATION="$iteration"
        local result
        run_iteration "$iteration" "$prompt_file" "$model"
        result=$?
        if [[ $result -eq 0 ]]; then
            log_success "Iteration $iteration completed successfully"
        elif [[ $result -eq 2 ]]; then
            log_info "Exit requested by user"
            return 0
        else
            log_warn "Iteration $iteration completed with issues"
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
