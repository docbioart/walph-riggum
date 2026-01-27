#!/usr/bin/env bash
# Ralph Wiggum - Utility Functions

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

# Check required dependencies
check_dependencies() {
    local missing=()

    if ! command_exists "claude"; then
        missing+=("claude (Claude CLI)")
    fi

    if ! command_exists "git"; then
        missing+=("git")
    fi

    if ! command_exists "jq"; then
        log_warn "jq not found - some features will be limited"
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies:"
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        return 1
    fi

    return 0
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
handle_rate_limit() {
    echo ""
    log_warn "API rate limit detected"
    echo ""
    echo "Options:"
    echo "  1. Wait and retry (will wait ${RATE_LIMIT_RETRY_DELAY:-60} seconds)"
    echo "  2. Exit and resume later"
    echo "  3. Continue anyway (may fail)"
    echo ""

    read -r -p "Choose [1/2/3]: " choice
    case "$choice" in
        1)
            log_info "Waiting ${RATE_LIMIT_RETRY_DELAY:-60} seconds before retry..."
            sleep "${RATE_LIMIT_RETRY_DELAY:-60}"
            return 0  # Retry
            ;;
        2)
            log_info "Exiting. Resume with: ralph build"
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

    # Create new tmux session or split existing
    if in_tmux; then
        # Split current pane
        tmux split-window -h "tail -f '$log_file'"
        tmux split-window -v "cd '$project_dir' && watch -n 2 'git status --short'"
    else
        # Create new session
        tmux new-session -d -s ralph-monitor "tail -f '$log_file'"
        tmux split-window -h -t ralph-monitor "cd '$project_dir' && watch -n 2 'git status --short'"
        tmux attach -t ralph-monitor
    fi
}

# ============================================================================
# VERSION AND HELP
# ============================================================================

RALPH_VERSION="1.0.0"

show_version() {
    echo "Ralph Wiggum v${RALPH_VERSION}"
}

show_help() {
    cat << 'EOF'
Ralph Wiggum - Autonomous Coding Loop

USAGE:
    ralph.sh <command> [options]

COMMANDS:
    init [name]       Initialize a new project (run 'ralph.sh init --help' for details)
    plan              Run in planning mode (generates IMPLEMENTATION_PLAN.md)
    build             Run in building mode (implements from plan) [default]
    status            Show current state and progress
    reset             Reset circuit breaker and state

OPTIONS:
    --max-iterations N    Maximum iterations (default: 50)
    --model MODEL         Override model for this run
    --monitor             Enable tmux monitoring view
    --dry-run             Show what would be run without executing
    -v, --verbose         Enable verbose output
    -h, --help            Show this help message
    --version             Show version

EXAMPLES:
    ralph.sh init my-app --stack node    # Initialize new project
    ralph.sh plan                        # Generate implementation plan
    ralph.sh build --max-iterations 10   # Build with limited iterations
    ralph.sh status                      # Check current progress

WORKFLOW:
    1. ralph.sh init my-app       # Create project structure
    2. Edit specs/TEMPLATE.md     # Write your requirements
    3. ralph.sh plan              # Generate task list
    4. ralph.sh build             # Implement everything

For more information, see README.md and QUICKSTART.md
EOF
}
