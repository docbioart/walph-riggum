#!/usr/bin/env bash
# Walph Riggum - Status Parser
# Parses WALPH_STATUS blocks from Claude output

# ============================================================================
# WALPH_STATUS BLOCK FORMAT
# ============================================================================
#
# WALPH_STATUS
# completion_level: HIGH|MEDIUM|LOW
# tasks_remaining: <number>
# current_task: <description>
# EXIT_SIGNAL: true|false
# WALPH_STATUS_END
#

# ============================================================================
# PARSING FUNCTIONS
# ============================================================================

# Extract WALPH_STATUS block from output
# Returns the block content or empty string if not found
extract_status_block() {
    local output="$1"

    # Extract the LAST complete block: Claude sometimes echoes the example
    # block from the prompt before emitting the real one at the end, and
    # concatenating multiple blocks makes every field a multiline value.
    # One pass over both marker styles (RALPH_STATUS from the prompt
    # templates, WALPH_STATUS legacy) so the genuinely last block wins
    # regardless of which markers it uses.
    local block
    block=$(printf '%s\n' "$output" | awk '
        /(RALPH|WALPH)_STATUS$/ && !/(RALPH|WALPH)_STATUS_END$/ { buf = ""; capturing = 1 }
        capturing { buf = buf $0 ORS }
        /(RALPH|WALPH)_STATUS_END$/ { capturing = 0; last = buf }
        END { printf "%s", last }')
    echo "$block"
}

# Parse a field from status block
# Usage: parse_status_field "$block" "completion_level"
parse_status_field() {
    local block="$1"
    local field="$2"

    # awk (first match then keep reading), not grep|head: head closing the
    # pipe early can SIGPIPE grep, and under pipefail that 141 aborts callers
    echo "$block" | awk -v f="$field" '
        index($0, f ":") == 1 && !found {
            found = 1
            line = substr($0, length(f) + 2)
            sub(/^[[:space:]]*/, "", line)
            print line
        }' | tr -d '\r'
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
# Matches actual Claude CLI/API error patterns, not arbitrary content
check_rate_limit() {
    local output="$1"

    # Only inspect the end of the output, where CLI/API errors actually land.
    # Project content earlier in the output (e.g. Claude writing retry code
    # that mentions rate_limit_error) must not trigger the interactive prompt.
    output=$(echo "$output" | tail -20)

    # Match specific error patterns from the Claude CLI:
    #   - "rate_limit_error" (API error type)
    #   - "Error: 429" (HTTP status from CLI)
    #   - "usage limit reached" (Claude Code billing cap message)
    #   - "too many requests" only when near "429" or "error" context
    #   - "Your limit will reset at" (Claude Code usage cap message)
    if echo "$output" | grep -q "rate_limit_error"; then
        return 0
    fi
    if echo "$output" | grep -q "Error: 429"; then
        return 0
    fi
    if echo "$output" | grep -qi "usage limit reached"; then
        return 0
    fi
    if echo "$output" | grep -qi "Your limit will reset at"; then
        return 0
    fi
    return 1  # Not rate limited
}

# Check for network/connection-level failures (distinct from rate limits and
# server errors: these mean the network is down, not that Claude is stuck —
# the loop should pause and retry, not count them toward the circuit breaker)
check_connection_error() {
    local output
    output=$(echo "$1" | tail -20)
    echo "$output" | grep -qiE "ECONNRESET|ECONNREFUSED|ConnectionRefused|Connection dropped|Connection refused|Unable to connect|ENOTFOUND|ETIMEDOUT|EAI_AGAIN|fetch failed|network is unreachable|CERTIFICATE_VERIFICATION_ERROR"
}

# Check for API error in output
check_api_error() {
    local output="$1"

    # Match specific error patterns from Claude CLI/API, not arbitrary mentions of status codes
    # Check only the last 10 lines where real errors typically appear
    local last_lines
    last_lines=$(echo "$output" | tail -10)

    if echo "$last_lines" | grep -qi "api.error\|server.error"; then
        return 0  # API error
    fi
    if echo "$last_lines" | grep -qi "Error: 500\|HTTP 500\|Internal Server Error"; then
        return 0  # HTTP 500 error
    fi
    if echo "$last_lines" | grep -qi "Error: 503\|HTTP 503\|Service Unavailable"; then
        return 0  # HTTP 503 error
    fi
    if echo "$last_lines" | grep -qi "overloaded\|server is overloaded"; then
        return 0  # Server overload
    fi
    return 1  # No API error
}

# Extract error message from output (best effort)
extract_error_message() {
    local output="$1"

    # Strip the status block first: it is the last thing Claude prints, and a
    # task description like "current_task: Add error handling" would otherwise
    # be harvested as an error and inflate the circuit breaker's same-error
    # count on a healthy run. Then search only the last 20 remaining lines.
    local last_lines
    last_lines=$(echo "$output" \
        | sed '/RALPH_STATUS$/,/RALPH_STATUS_END/d; /WALPH_STATUS$/,/WALPH_STATUS_END/d' \
        | tail -20)

    # Try to find common error patterns
    local error_line
    error_line=$(echo "$last_lines" | grep -i "error\|failed\|exception" | head -1)

    if [[ -n "$error_line" ]]; then
        echo "$error_line"
    fi
}
