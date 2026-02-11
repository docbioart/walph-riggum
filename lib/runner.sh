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

    # Substitute common variables in prompt
    full_prompt=$(echo "$full_prompt" | sed "s/{{ITERATION}}/$iteration/g")
    full_prompt=$(echo "$full_prompt" | sed "s/{{MAX_ITERATIONS}}/$MAX_ITERATIONS/g")
    full_prompt=$(echo "$full_prompt" | sed "s/{{MODE}}/$MODE/g")

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
    temp_prompt=$(mktemp)
    printf '%s' "$full_prompt" > "$temp_prompt"

    local temp_output
    temp_output=$(mktemp)

    # Run Claude in the background with a timeout watchdog.
    # Using a temp file for input (not pipe) ensures clean EOF delivery.
    # The background PID lets us kill it if it exceeds the timeout.
    claude -p \
        --dangerously-skip-permissions \
        --model "$model" \
        < "$temp_prompt" \
        > "$temp_output" 2>&1 &
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

    # Stream output to terminal (tee equivalent, after the fact)
    cat "$temp_output"
    output=$(cat "$temp_output")
    rm -f "$temp_output"

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

    # Check for completion
    if check_completion "$output"; then
        log_success "Completion signal received!"
        # Write signal file so main_loop breaks after this iteration
        touch "$PROJECT_DIR/$state_dir/completion_signal"
        return 0
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
            return 0
        fi

        ((iteration++))

        # Small delay between iterations
        sleep 1
    done

    log_warn "Maximum iterations ($MAX_ITERATIONS) reached"
    return 0
}
