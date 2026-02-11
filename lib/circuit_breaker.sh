#!/usr/bin/env bash
# Walph Riggum - Circuit Breaker
# Detects when the loop is stuck and should stop

# ============================================================================
# STATE FILE MANAGEMENT
# ============================================================================

CIRCUIT_BREAKER_STATE_FILE=""

init_circuit_breaker() {
    local state_dir="$1"
    CIRCUIT_BREAKER_STATE_FILE="$state_dir/circuit_breaker.json"

    # Initialize state file if it doesn't exist
    if [[ ! -f "$CIRCUIT_BREAKER_STATE_FILE" ]]; then
        echo '{"no_change_count":0,"same_error_count":0,"no_commit_count":0,"last_error":"","last_git_hash":"","iteration_history":[]}' > "$CIRCUIT_BREAKER_STATE_FILE"
    fi
}

# Read a value from state file
_read_state() {
    local key="$1"
    if command -v jq &>/dev/null && [[ -f "$CIRCUIT_BREAKER_STATE_FILE" ]]; then
        jq -r ".$key // empty" "$CIRCUIT_BREAKER_STATE_FILE" 2>/dev/null
    fi
}

# Update state file
_update_state() {
    local key="$1"
    local value="$2"
    local is_number="${3:-false}"

    if command -v jq &>/dev/null && [[ -f "$CIRCUIT_BREAKER_STATE_FILE" ]]; then
        local tmp_file
        tmp_file=$(mktemp)
        if [[ "$is_number" == "true" ]]; then
            jq ".$key = $value" "$CIRCUIT_BREAKER_STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$CIRCUIT_BREAKER_STATE_FILE"
        else
            # Use --arg to safely pass string values with special characters
            jq --arg val "$value" ".$key = \$val" "$CIRCUIT_BREAKER_STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$CIRCUIT_BREAKER_STATE_FILE"
        fi
    fi
}

# ============================================================================
# DETECTION LOGIC
# ============================================================================

# Check if any files changed since last iteration
check_file_changes() {
    local current_hash
    current_hash=$(git rev-parse HEAD 2>/dev/null || echo "no-git")
    local last_hash
    last_hash=$(_read_state "last_git_hash")

    # Check working directory changes (exclude state dirs to avoid self-resets)
    local working_changes
    working_changes=$(git status --porcelain 2>/dev/null | grep -v '\.walph/state/\|\.goodbunny/state/' | wc -l | tr -d ' ')

    if [[ "$current_hash" != "$last_hash" ]] || [[ "$working_changes" -gt 0 ]]; then
        return 0  # Changes detected
    fi
    return 1  # No changes
}

# Check for repeated error patterns
check_error_pattern() {
    local current_error="$1"
    local last_error
    last_error=$(_read_state "last_error")

    if [[ -n "$current_error" ]] && [[ "$current_error" == "$last_error" ]]; then
        return 0  # Same error
    fi
    return 1  # Different error or no error
}

# Check for explicit stuck signal from Claude
check_stuck_signal() {
    local output="$1"
    if echo "$output" | grep -q "WALPH_STUCK\|RALPH_STUCK\|GOODBUNNY_STUCK"; then
        return 0  # Stuck signal found
    fi
    return 1  # No stuck signal
}

# Check if there have been meaningful commits recently
# Commits that only touch state dirs are not counted (avoids self-resets)
check_commit_activity() {
    local current_hash
    current_hash=$(git rev-parse HEAD 2>/dev/null || echo "no-git")
    local last_hash
    last_hash=$(_read_state "last_git_hash")

    if [[ "$current_hash" != "$last_hash" ]]; then
        # Verify the commit touched files outside state dirs
        local meaningful_files
        meaningful_files=$(git diff --name-only "$last_hash" "$current_hash" 2>/dev/null | grep -v '\.walph/state/\|\.goodbunny/state/' | wc -l | tr -d ' ')
        if [[ "$meaningful_files" -gt 0 ]]; then
            return 0  # New meaningful commit
        fi
        # Commit only touched state files — don't count it, but update hash
        # so we don't re-check this same commit range next iteration
        _update_state "last_git_hash" "$current_hash"
        return 1  # No meaningful commit
    fi
    return 1  # No new commit
}

# ============================================================================
# MAIN CIRCUIT BREAKER FUNCTIONS
# ============================================================================

# Update circuit breaker state after an iteration
# Returns: 0 if OK to continue, 1 if should stop
update_circuit_breaker() {
    local iteration_output="$1"
    local error_output="$2"

    # Get current counters
    local no_change_count
    no_change_count=$(_read_state "no_change_count")
    no_change_count=${no_change_count:-0}

    local same_error_count
    same_error_count=$(_read_state "same_error_count")
    same_error_count=${same_error_count:-0}

    local no_commit_count
    no_commit_count=$(_read_state "no_commit_count")
    no_commit_count=${no_commit_count:-0}

    # Check for explicit stuck signal
    if check_stuck_signal "$iteration_output"; then
        log_warn "Claude signaled WALPH_STUCK"
        return 1
    fi

    # Check file changes
    if check_file_changes; then
        no_change_count=0
        log_debug "File changes detected, reset no_change_count"
    else
        ((no_change_count++))
        log_debug "No file changes, no_change_count=$no_change_count"
    fi
    _update_state "no_change_count" "$no_change_count" "true"

    # Check error patterns
    if [[ -n "$error_output" ]]; then
        if check_error_pattern "$error_output"; then
            ((same_error_count++))
            log_debug "Same error repeated, same_error_count=$same_error_count"
        else
            same_error_count=1
            _update_state "last_error" "$error_output"
        fi
    else
        same_error_count=0
    fi
    _update_state "same_error_count" "$same_error_count" "true"

    # Check commit activity
    if check_commit_activity; then
        no_commit_count=0
        # Update last git hash
        local current_hash
        current_hash=$(git rev-parse HEAD 2>/dev/null || echo "no-git")
        _update_state "last_git_hash" "$current_hash"
        log_debug "New commit detected, reset no_commit_count"
    else
        ((no_commit_count++))
        log_debug "No new commit, no_commit_count=$no_commit_count"
    fi
    _update_state "no_commit_count" "$no_commit_count" "true"

    return 0
}

# Check if circuit breaker should trigger
# Returns: 0 if triggered (should stop), 1 if OK to continue
circuit_breaker_triggered() {
    local no_change_count
    no_change_count=$(_read_state "no_change_count")
    no_change_count=${no_change_count:-0}

    local same_error_count
    same_error_count=$(_read_state "same_error_count")
    same_error_count=${same_error_count:-0}

    local no_commit_count
    no_commit_count=$(_read_state "no_commit_count")
    no_commit_count=${no_commit_count:-0}

    # Check thresholds
    if [[ "$no_change_count" -ge "${CIRCUIT_BREAKER_NO_CHANGE_THRESHOLD:-3}" ]]; then
        log_error "Circuit breaker: No file changes for $no_change_count iterations"
        return 0
    fi

    if [[ "$same_error_count" -ge "${CIRCUIT_BREAKER_SAME_ERROR_THRESHOLD:-5}" ]]; then
        log_error "Circuit breaker: Same error repeated $same_error_count times"
        return 0
    fi

    # Only check commit threshold in build mode
    if [[ "${TOOL_MODE:-${WALPH_MODE:-build}}" == "build" ]] || [[ "${TOOL_MODE:-${WALPH_MODE:-build}}" == "fix" ]]; then
        if [[ "$no_commit_count" -ge "${CIRCUIT_BREAKER_NO_COMMIT_THRESHOLD:-5}" ]]; then
            log_error "Circuit breaker: No commits for $no_commit_count iterations"
            return 0
        fi
    fi

    return 1  # OK to continue
}

# Reset circuit breaker state
reset_circuit_breaker() {
    if [[ -n "$CIRCUIT_BREAKER_STATE_FILE" ]]; then
        local current_hash
        current_hash=$(git rev-parse HEAD 2>/dev/null || echo "no-git")
        echo "{\"no_change_count\":0,\"same_error_count\":0,\"no_commit_count\":0,\"last_error\":\"\",\"last_git_hash\":\"$current_hash\",\"iteration_history\":[]}" > "$CIRCUIT_BREAKER_STATE_FILE"
    fi
}

# Get circuit breaker status summary
get_circuit_breaker_status() {
    local no_change_count
    no_change_count=$(_read_state "no_change_count")
    local same_error_count
    same_error_count=$(_read_state "same_error_count")
    local no_commit_count
    no_commit_count=$(_read_state "no_commit_count")

    echo "no_change=$no_change_count same_error=$same_error_count no_commit=$no_commit_count"
}
