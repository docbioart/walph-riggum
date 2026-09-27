#!/usr/bin/env bash
# Walph Riggum - Utility Functions

# ============================================================================
# GENERAL UTILITIES
# ============================================================================

# Generate a unique session ID
generate_session_id() {
    date '+%Y%m%d_%H%M%S'
}

# Check if a command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Replace every occurrence of a placeholder with literal replacement text.
# Safe for replacement text containing &, \, or other characters that bash
# ${var//pat/rep} interprets on some versions (patsub_replacement in 5.2+).
# Usage: substitute_placeholder "$content" "{{NAME}}" "$replacement"
substitute_placeholder() {
    local content="$1"
    local placeholder="$2"
    local replacement="$3"
    local result=""

    while [[ "$content" == *"$placeholder"* ]]; do
        result+="${content%%"$placeholder"*}$replacement"
        content="${content#*"$placeholder"}"
    done
    printf '%s' "$result$content"
}

# Check required dependencies: the resolved harness CLI, git, and jq
check_dependencies() {
    local missing=()

    if ! harness_check_installed "${HARNESS:-claude}"; then
        missing+=("${HARNESS:-claude} (agent CLI)")
    fi

    if ! command_exists "git"; then
        missing+=("git")
    fi

    if ! command_exists "jq"; then
        missing+=("jq")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies:"
        local dep
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        return 1
    fi

    return 0
}

# Advisory check: does the selected harness have a chrome-devtools MCP server
# configured? Looks only at that harness's own config files, since a server
# configured for one CLI is not evidence another CLI can use it.
# Usage: check_chrome_mcp [harness]
check_chrome_mcp() {
    local harness="${1:-${HARNESS:-claude}}"
    local project_dir="${PROJECT_DIR:-.}"
    local candidates=()

    case "$harness" in
        claude)
            candidates=(
                "${HOME}/.claude.json"
                "${HOME}/.claude/mcp.json"
                "${project_dir}/.mcp.json"
                "${HOME}/.config/claude/claude_desktop_config.json"
                "${HOME}/Library/Application Support/Claude/claude_desktop_config.json"
            )
            ;;
        codex)
            candidates=(
                "${CODEX_HOME:-${HOME}/.codex}/config.toml"
                "${project_dir}/.codex/config.toml"
            )
            ;;
        opencode)
            candidates=(
                "${OPENCODE_CONFIG:-}"
                "${XDG_CONFIG_HOME:-${HOME}/.config}/opencode/opencode.json"
                "${XDG_CONFIG_HOME:-${HOME}/.config}/opencode/opencode.jsonc"
                "${project_dir}/opencode.json"
                "${project_dir}/opencode.jsonc"
            )
            ;;
    esac

    local file
    for file in ${candidates[@]+"${candidates[@]}"}; do
        [[ -n "$file" ]] && [[ -f "$file" ]] || continue
        if grep -q "chrome-devtools" "$file" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# ============================================================================
# CONNECTIVITY
# ============================================================================

# Block until the agent's API endpoint is reachable again. Any HTTP response
# (even 4xx) proves the network path works; curl only fails on
# connection/DNS/TLS problems. Returns 0 once online, 1 after the maximum
# wait (WALPH_OFFLINE_MAX_WAIT, default 4 hours — sized for a multi-hour
# outage).
wait_for_connectivity() {
    # Probe the API the current harness talks to (OpenCode's provider is not
    # knowable from here; set WALPH_CONNECTIVITY_URL for it)
    local default_url="https://api.anthropic.com/"
    [[ "${HARNESS:-claude}" == "codex" ]] && default_url="https://api.openai.com/"
    local probe_url="${WALPH_CONNECTIVITY_URL:-$default_url}"
    local max_wait="${WALPH_OFFLINE_MAX_WAIT:-14400}"
    local interval="${WALPH_OFFLINE_RETRY_INTERVAL:-60}"
    local waited=0

    while ! curl -s -m 10 -o /dev/null "$probe_url"; do
        if [[ $waited -ge $max_wait ]]; then
            return 1
        fi
        if (( waited % 600 == 0 )); then
            log_warn "Offline for $((waited / 60)) min — probing every ${interval}s (giving up after $((max_wait / 60)) min)"
        fi
        sleep "$interval"
        waited=$((waited + interval))
    done
    return 0
}

# ============================================================================
# RUN LOCK
# ============================================================================

# Refuse to start a second autonomous loop against the same project — two
# loops mutating one working tree commit torn mixes of each other's edits
# (observed live on 2026-08-24: three concurrent walph runs during a network
# outage). noclobber write is the atomic claim; a dead PID means stale lock.
#
# Usage: acquire_run_lock <lock_file> <tool_name>
# Sets RUN_LOCK_FILE on success (caller's EXIT trap must rm it); exits 1 if
# another live run holds the lock.
acquire_run_lock() {
    local lock_file="$1"
    local tool_name="${2:-walph}"

    if ! ( set -o noclobber; echo "$$" > "$lock_file" ) 2>/dev/null; then
        local lock_pid
        lock_pid=$(cat "$lock_file" 2>/dev/null || true)
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            log_error "Another $tool_name run (PID $lock_pid) is already active in this project"
            log_info "Two loops mutating one working tree corrupt each other's commits."
            log_info "Wait for it to finish, or stop it first with: kill $lock_pid"
            exit 1
        fi
        log_warn "Removing stale $tool_name lock (PID ${lock_pid:-unknown} is gone)"
        echo "$$" > "$lock_file"
    fi
    RUN_LOCK_FILE="$lock_file"
}

release_run_lock() {
    if [[ -n "${RUN_LOCK_FILE:-}" ]]; then
        rm -f "$RUN_LOCK_FILE" 2>/dev/null || true
        RUN_LOCK_FILE=""
    fi
}

# ============================================================================
# FILE UTILITIES
# ============================================================================

# Check if we're in a git repository
is_git_repo() {
    git rev-parse --git-dir &>/dev/null
}

# Warn once when the project is not a git repository: the circuit breaker's
# no-change and no-commit detectors are disabled there
warn_if_not_git_repo() {
    if is_git_repo; then
        return 0
    fi
    log_warn "Not a git repository: change and commit detection are disabled, so the loop only stops on repeated errors, a stuck signal, or the iteration limit"
    log_info "Run 'git init' (or 'walph setup', which does it) to enable the full circuit breaker"
    return 0
}

# Get project root (git root or current directory)
get_project_root() {
    if is_git_repo; then
        git rev-parse --show-toplevel
    else
        pwd
    fi
}

# Check if a file exists and is readable
file_readable() {
    [[ -f "$1" ]] && [[ -r "$1" ]]
}

# Safely read a file, returning empty on error
safe_read_file() {
    local file="$1"
    if file_readable "$file"; then
        cat "$file"
    fi
}

# Count real spec files in a specs directory (excludes README.md and TEMPLATE.md).
# Echoes 0 if the directory doesn't exist.
count_spec_files() {
    local specs_dir="$1"
    # Guard the missing-dir case: under set -e/pipefail, a failing find
    # would abort the caller
    if [[ ! -d "$specs_dir" ]]; then
        echo 0
        return
    fi
    find "$specs_dir" -maxdepth 1 -name "*.md" -not -name "README.md" -not -name "TEMPLATE.md" | wc -l | tr -d ' '
}

# ============================================================================
# PROMPT UTILITIES
# ============================================================================

# Ask user a yes/no question
# Returns 0 for yes, 1 for no
ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"  # Default to no

    local yn_prompt
    if [[ "$default" == "y" ]]; then
        yn_prompt="[Y/n]"
    else
        yn_prompt="[y/N]"
    fi

    while true; do
        read -r -p "$prompt $yn_prompt " answer
        answer=${answer:-$default}
        case "$answer" in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer yes or no." >&2;;  # stderr: callers may capture stdout
        esac
    done
}

# Ask user to choose from options
# Usage: ask_choice "prompt" "option1" "option2" "option3"
# Returns the chosen option number (1-based)
ask_choice() {
    local prompt="$1"
    shift
    local options=("$@")

    echo "$prompt"
    local i=1
    for opt in "${options[@]}"; do
        echo "  $i. $opt"
        ((i++))
    done

    while true; do
        read -r -p "Choose [1-${#options[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#options[@]} ]]; then
            return "$choice"
        fi
        echo "Invalid choice. Please enter a number between 1 and ${#options[@]}."
    done
}

# ============================================================================
# RATE LIMIT HANDLING
# ============================================================================

# Handle rate limit with user interaction
# Args: [claude_output] - optional raw output from Claude for detail extraction
# Seconds until the reset time a Claude Code cap message names ("resets 1pm",
# "Your limit will reset at 3:30pm"), plus a two-minute grace; empty when the output
# names no parseable time. Pure-bash clock arithmetic (no GNU/BSD `date -d` split):
# today's midnight = now minus the H/M/S read from `date`, target = that + the
# parsed clock time, rolled to tomorrow when already past. Capped at 24h.
rate_limit_reset_delay() {
    local output="${1:-}"
    local hint
    hint=$(printf '%s\n' "$output" | grep -oiE "reset(s)?( at)? [0-9]{1,2}(:[0-9]{2})? ?(am|pm)" | head -1)
    [[ -z "$hint" ]] && return 0
    local clock ampm hour minute
    clock=$(printf '%s' "$hint" | grep -oE "[0-9]{1,2}(:[0-9]{2})?")
    ampm=$(printf '%s' "$hint" | grep -oiE "am|pm" | tr '[:upper:]' '[:lower:]')
    hour=${clock%%:*}; minute=0
    [[ "$clock" == *:* ]] && minute=${clock#*:}
    hour=$((10#$hour)); minute=$((10#$minute))
    [[ "$ampm" == "pm" && $hour -lt 12 ]] && hour=$((hour + 12))
    [[ "$ampm" == "am" && $hour -eq 12 ]] && hour=0
    local now midnight target
    now=$(date +%s)
    midnight=$(( now - (10#$(date +%H) * 3600 + 10#$(date +%M) * 60 + 10#$(date +%S)) ))
    target=$(( midnight + hour * 3600 + minute * 60 ))
    [[ $target -le $now ]] && target=$(( target + 86400 ))
    local delay=$(( target - now + 120 ))
    [[ $delay -gt 86400 ]] && delay=86400
    printf '%s' "$delay"
}

handle_rate_limit() {
    local claude_output="${1:-}"
    local delay="${RATE_LIMIT_RETRY_DELAY:-60}"

    # Non-interactive session (nohup, CI, overnight run): nobody can answer
    # the prompt, so wait and retry instead of dying on a failed read. When the
    # message names its reset time, sleep until then rather than polling every
    # minute against a cap that will not lift for hours.
    if [[ ! -t 0 ]]; then
        local until_reset
        until_reset=$(rate_limit_reset_delay "$claude_output")
        if [[ -n "$until_reset" && "$until_reset" -gt "$delay" ]]; then
            delay="$until_reset"
        fi
        log_warn "API rate limit detected — non-interactive session, waiting ${delay}s before retrying"
        sleep "$delay"
        return 0
    fi

    echo ""
    log_warn "API rate limit detected"
    echo ""
    echo "  The Claude API returned a rate limit error (HTTP 429). This means either:"
    echo "  - You've hit your per-minute request/token limit (wait and retry)"
    echo "  - You've reached your plan's usage cap (resets on a timer)"
    echo ""

    # Try to extract the specific error message from Claude's output
    if [[ -n "$claude_output" ]]; then
        local detail=""
        # Look for the structured API error message first
        detail=$(printf '%s\n' "$claude_output" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message":"//;s/"$//')
        # Fall back to the CLI usage limit message
        if [[ -z "$detail" ]]; then
            detail=$(printf '%s\n' "$claude_output" | grep -i "usage limit reached\|Your limit will reset at\|Error: 429" | head -1)
        fi
        if [[ -n "$detail" ]]; then
            echo "  Error detail: $detail"
            echo ""
        fi
    fi

    # Show context if available
    if [[ -n "${MODEL_BUILD:-}" ]]; then
        echo "  Model: ${MODEL_BUILD}"
    fi
    if [[ -n "${WALPH_CURRENT_ITERATION:-}" ]]; then
        echo "  Iteration: ${WALPH_CURRENT_ITERATION}/${MAX_ITERATIONS:-?}"
    fi
    if [[ -n "${MODEL_BUILD:-}${WALPH_CURRENT_ITERATION:-}" ]]; then
        echo ""
    fi

    echo "  Your progress is safe — all completed tasks have been committed."
    echo "  You can resume exactly where you left off with '${RESUME_COMMAND:-walph build}'."
    echo ""
    echo "Options:"
    echo "  1. Wait and retry (will wait ${delay} seconds)"
    echo "  2. Exit and resume later (recommended)"
    echo "  3. Continue anyway (will likely fail again)"
    echo ""

    read -r -p "Choose [1/2/3]: " choice
    case "$choice" in
        1)
            log_info "Waiting ${delay} seconds before retry..."
            sleep "$delay"
            return 0  # Retry
            ;;
        2)
            log_info "Exiting. Resume with: ${RESUME_COMMAND:-walph build}"
            return 2  # Exit
            ;;
        3)
            log_warn "Continuing despite rate limit"
            return 0  # Continue
            ;;
        *)
            return 2  # Default to exit
            ;;
    esac
}

# ============================================================================
# TMUX UTILITIES
# ============================================================================

# Check if running inside tmux
in_tmux() {
    [[ -n "${TMUX:-}" ]]  # :- guard: unset TMUX is fatal under set -u
}

# Start monitoring session in tmux
start_monitor_session() {
    local log_file="$1"
    local project_dir="$2"

    if ! command_exists "tmux"; then
        log_warn "tmux not found, monitoring disabled"
        return 1
    fi

    # Escape paths for shell safety (handles quotes and special chars)
    local escaped_log_file escaped_project_dir
    escaped_log_file=$(printf '%q' "$log_file")
    escaped_project_dir=$(printf '%q' "$project_dir")

    # Create new tmux session or split existing
    if in_tmux; then
        # Split current pane
        tmux split-window -h "tail -f $escaped_log_file"
        tmux split-window -v "cd $escaped_project_dir && watch -n 2 'git status --short'"
    else
        # Create new session
        tmux new-session -d -s walph-monitor "tail -f $escaped_log_file"
        tmux split-window -h -t walph-monitor "cd $escaped_project_dir && watch -n 2 'git status --short'"
        tmux attach -t walph-monitor
    fi
}
