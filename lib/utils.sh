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
# FILE UTILITIES
# ============================================================================

# Check if we're in a git repository
is_git_repo() {
    git rev-parse --git-dir &>/dev/null
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
            * ) echo "Please answer yes or no.";;
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
handle_rate_limit() {
    local claude_output="${1:-}"
    local delay="${RATE_LIMIT_RETRY_DELAY:-60}"

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
    [[ -n "$TMUX" ]]
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
