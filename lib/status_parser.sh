#!/usr/bin/env bash
# Ralph Wiggum - Status Parser
# Parses RALPH_STATUS blocks from Claude output

# ============================================================================
# RALPH_STATUS BLOCK FORMAT
# ============================================================================
#
# RALPH_STATUS
# completion_level: HIGH|MEDIUM|LOW
# tasks_remaining: <number>
# current_task: <description>
# EXIT_SIGNAL: true|false
# RALPH_STATUS_END
#

# ============================================================================
# PARSING FUNCTIONS
# ============================================================================

# Extract RALPH_STATUS block from output
# Returns the block content or empty string if not found
extract_status_block() {
    local output="$1"

    # Use sed to extract between markers
    echo "$output" | sed -n '/RALPH_STATUS$/,/RALPH_STATUS_END/p' 2>/dev/null
}

# Parse a field from status block
# Usage: parse_status_field "$block" "completion_level"
parse_status_field() {
    local block="$1"
    local field="$2"

    echo "$block" | grep "^${field}:" | sed "s/^${field}:[[:space:]]*//" | tr -d '\r'
}

# Parse complete status into associative array (bash 4+)
# Usage: parse_status "$output" status_array
parse_status() {
    local output="$1"
    local -n result_array=$2  # nameref

    local block
    block=$(extract_status_block "$output")

    if [[ -z "$block" ]]; then
        return 1  # No status block found
    fi

    result_array[completion_level]=$(parse_status_field "$block" "completion_level")
    result_array[tasks_remaining]=$(parse_status_field "$block" "tasks_remaining")
    result_array[current_task]=$(parse_status_field "$block" "current_task")
    result_array[exit_signal]=$(parse_status_field "$block" "EXIT_SIGNAL")

    return 0
}

# Check if output indicates completion (dual-gate check)
# Returns 0 if should exit, 1 if should continue
check_completion() {
    local output="$1"

    local block
    block=$(extract_status_block "$output")

    if [[ -z "$block" ]]; then
        return 1  # No status block, continue
    fi

    local completion_level
    completion_level=$(parse_status_field "$block" "completion_level")
    local exit_signal
    exit_signal=$(parse_status_field "$block" "EXIT_SIGNAL")

    # Dual-gate: both must be true
    if [[ "$completion_level" == "HIGH" ]] && [[ "$exit_signal" == "true" ]]; then
        return 0  # Should exit
    fi

    return 1  # Should continue
}

# Get human-readable status summary
get_status_summary() {
    local output="$1"

    local block
    block=$(extract_status_block "$output")

    if [[ -z "$block" ]]; then
        echo "No status reported"
        return
    fi

    local completion_level
    completion_level=$(parse_status_field "$block" "completion_level")
    local tasks_remaining
    tasks_remaining=$(parse_status_field "$block" "tasks_remaining")
    local current_task
    current_task=$(parse_status_field "$block" "current_task")
    local exit_signal
    exit_signal=$(parse_status_field "$block" "EXIT_SIGNAL")

    echo "Completion: $completion_level | Tasks remaining: $tasks_remaining | Exit: $exit_signal"
    if [[ -n "$current_task" ]]; then
        echo "Current task: $current_task"
    fi
}

# ============================================================================
# ERROR DETECTION
# ============================================================================

# Check for rate limit error in output
check_rate_limit() {
    local output="$1"

    if echo "$output" | grep -qi "rate.limit\|429\|too.many.requests\|5-hour"; then
        return 0  # Rate limited
    fi
    return 1  # Not rate limited
}

# Check for API error in output
check_api_error() {
    local output="$1"

    if echo "$output" | grep -qi "api.error\|server.error\|500\|503\|overloaded"; then
        return 0  # API error
    fi
    return 1  # No API error
}

# Extract error message from output (best effort)
extract_error_message() {
    local output="$1"

    # Try to find common error patterns
    local error_line
    error_line=$(echo "$output" | grep -i "error\|failed\|exception" | head -1)

    if [[ -n "$error_line" ]]; then
        echo "$error_line"
    fi
}
