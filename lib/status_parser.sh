#!/usr/bin/env bash
# Walph Riggum - Status Parser
# Parses the RALPH_STATUS block from the agent's final response, and
# classifies structured error messages from the harness.

# ============================================================================
# STATUS BLOCK FORMAT
# ============================================================================
#
# RALPH_STATUS                 (WALPH_STATUS is accepted as a legacy spelling)
# completion_level: HIGH|MEDIUM|LOW
# tasks_remaining: <number>
# current_task: <description>
# EXIT_SIGNAL: true|false
# RALPH_STATUS_END
#
# Only the LAST block in the response counts. Agents sometimes quote the
# template earlier in their answer, and two blocks would otherwise produce
# doubled fields that never match the completion check.

# ============================================================================
# PARSING FUNCTIONS
# ============================================================================

# Extract the last status block from the final response text
# Returns the block content or empty string if not found
extract_status_block() {
    local output="$1"
    printf '%s\n' "$output" | awk '
        /(RALPH|WALPH)_STATUS$/     { buf = $0 "\n"; inblock = 1; next }
        inblock                     { buf = buf $0 "\n" }
        /(RALPH|WALPH)_STATUS_END/  { if (inblock) { last = buf }; inblock = 0 }
        END                         { printf "%s", last }
    '
}

# Parse a field from status block
# Usage: parse_status_field "$block" "completion_level"
parse_status_field() {
    local block="$1"
    local field="$2"

    # awk (first match, then keep reading), not grep|head: head closing the
    # pipe early can SIGPIPE grep, and under pipefail that 141 aborts callers
    printf '%s\n' "$block" | awk -v f="$field" '
        index($0, f ":") == 1 && !found {
            found = 1
            line = substr($0, length(f) + 2)
            sub(/^[[:space:]]*/, "", line)
            print line
        }' | tr -d '\r'
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
# ERROR CLASSIFICATION
# ============================================================================
#
# These functions receive the harness's structured error channel
# (HARNESS_ERRORS: turn.failed / error events, is_error results, error-looking
# stderr lines) — never the agent's prose. That keeps an agent that merely
# *talks about* a 429 from tripping the rate-limit handler.

# Check for a rate limit / usage cap error
check_rate_limit() {
    local errors="$1"
    [[ -z "$errors" ]] && return 1

    # "hit your … limit" is Claude Code's cap wording ("You've hit your weekly
    # limit · resets 1pm"): on 2026-08-31 an overnight run burned three empty
    # iterations into the breaker because nothing matched it.
    if printf '%s\n' "$errors" | grep -qiE 'rate.?limit|rate_limit_error|(^|[^0-9])429([^0-9]|$)|usage limit|your limit will reset|hit your (weekly |usage |daily |session )?limit|quota (exceeded|reached)|exceeded[a-z ]* quota|insufficient_quota'; then
        return 0
    fi
    return 1
}

# Check for a network/connection-level failure. Distinct from rate limits and
# server errors: these mean the network is down, not that the agent is stuck,
# so the loop pauses and retries instead of feeding the circuit breaker.
check_connection_error() {
    local errors="$1"
    [[ -z "$errors" ]] && return 1
    printf '%s\n' "$errors" | grep -qiE 'ECONNRESET|ECONNREFUSED|ConnectionRefused|Connection dropped|Connection refused|Unable to connect|ENOTFOUND|ETIMEDOUT|EAI_AGAIN|fetch failed|network is unreachable|CERTIFICATE_VERIFICATION_ERROR'
}

# Check for a server-side API error (5xx, overloaded, failed turn)
check_api_error() {
    local errors="$1"
    [[ -z "$errors" ]] && return 1

    if printf '%s\n' "$errors" | grep -qiE 'api.?error|server.?error|(^|[^0-9])50[0-9]([^0-9]|$)|internal server error|service unavailable|overloaded|turn\.failed|error_during_execution'; then
        return 0
    fi
    return 1
}

# First structured error line (fed to the circuit breaker's same-error counter)
extract_error_message() {
    local errors="$1"
    [[ -z "$errors" ]] && return 0
    printf '%s\n' "$errors" | grep -v '^[[:space:]]*$' | head -1
}
