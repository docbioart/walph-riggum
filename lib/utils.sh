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
        missing+=("jq")
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

# ============================================================================
# VERSION AND HELP
# ============================================================================

WALPH_VERSION="1.0.0"

show_version() {
    echo "Walph Riggum v${WALPH_VERSION}"
}

show_howto() {
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════════════════╗
║                           WALPH RIGGUM                                        ║
║                    Autonomous Coding Loop for Claude                          ║
╚═══════════════════════════════════════════════════════════════════════════════╝

Walph runs Claude in an autonomous loop to plan and build software projects.
It uses Opus for planning and Sonnet for building, with fresh context each iteration.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 QUICK START
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  NEW PROJECT:
    walph init my-app --template api      # Create new project
    cd my-app
    # Edit specs/TEMPLATE.md with your requirements
    walph plan                            # Generate task list
    walph build                           # Build it!

  EXISTING PROJECT:
    cd your-project
    walph setup                           # Add Walph config (auto-detects stack)
    # Edit AGENTS.md with your build/test commands
    # Write specs in specs/
    walph plan                            # Generate task list
    walph build                           # Build it!

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 COMMANDS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  walph init <name> [options]   Create a new project
    --template <type>           api, fullstack, cli, ios, android, capacitor, monorepo
    --stack <lang>              node, python, swift, kotlin
    --docker                    Include Docker configuration
    --postgres                  Include PostgreSQL setup

  walph setup [options]         Add Walph to existing project
    --stack <lang>              Override auto-detected stack
    --force                     Overwrite existing Walph files

  walph plan [options]          Generate implementation plan from specs
    --max-iterations N          Limit iterations (default: 50)
    --model <name>              Override model (default: opus)

  walph build [options]         Build from implementation plan
    --max-iterations N          Limit iterations (default: 50)
    --model <name>              Override model (default: sonnet)
    --monitor                   Enable tmux monitoring view

  walph status                  Show current progress
  walph reset                   Reset circuit breaker (if stuck)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 HOW IT WORKS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  1. WRITE SPECS          You describe what to build in specs/*.md
                          Be specific: endpoints, inputs, outputs, examples

  2. PLAN (Opus)          Claude analyzes specs and generates tasks
                          Creates IMPLEMENTATION_PLAN.md with checkboxes

  3. BUILD (Sonnet)       Claude implements ONE task per iteration:
                          - Picks first unchecked task
                          - Writes code, runs tests
                          - Marks task complete [x]
                          - Commits changes
                          - Repeats until done

  4. CIRCUIT BREAKER      Auto-stops if stuck:
                          - No file changes for 3 iterations
                          - Same error 5 times
                          - No commits for 5 iterations

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 PROJECT STRUCTURE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  your-project/
  ├── .walph/                    # Walph configuration
  │   ├── config                 # Settings (iterations, models, thresholds)
  │   ├── PROMPT_plan.md         # Planning prompt (customizable)
  │   ├── PROMPT_build.md        # Building prompt (customizable)
  │   ├── logs/                  # Session logs
  │   └── state/                 # Circuit breaker state
  ├── specs/                     # Your requirements
  │   └── *.md                   # Feature specs (Walph reads all .md files)
  ├── AGENTS.md                  # Build/test/lint commands for Claude
  └── IMPLEMENTATION_PLAN.md     # Task list (generated by 'walph plan')

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 WRITING GOOD SPECS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  GOOD SPEC:                              BAD SPEC:
  ┌─────────────────────────────────┐     ┌─────────────────────────────────┐
  │ POST /users                     │     │ Handle user management          │
  │ Request: { "email": "..." }     │     │                                 │
  │ Response: { "id": 1, ... }      │     │                                 │
  │ Returns 400 if email invalid    │     │                                 │
  └─────────────────────────────────┘     └─────────────────────────────────┘

  Include:
  - Specific endpoints, function signatures, or CLI commands
  - Input/output examples
  - Error cases
  - Files to create/modify
  - Acceptance criteria as checkboxes

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 TIPS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  • Start small - first project should be simple
  • Review the plan - edit IMPLEMENTATION_PLAN.md before building if needed
  • Watch logs - tail -f .walph/logs/*.log
  • If stuck - walph reset, then check specs clarity
  • Commit often - Walph commits after each task (this is good!)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 MORE INFO
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  walph --help              Full command reference
  walph init --help         Project initialization options
  walph setup --help        Existing project setup options
  See: README.md, QUICKSTART.md

EOF
}

show_help() {
    cat << 'EOF'
Walph Riggum - Autonomous Coding Loop

USAGE:
    walph.sh <command> [options]

COMMANDS:
    init [name]       Initialize a new project (run 'walph init --help' for details)
    setup             Add Walph to existing project (run 'walph setup --help' for details)
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
    # New project
    walph.sh init my-app --stack node    # Initialize new project

    # Existing project
    cd my-existing-project
    walph.sh setup                       # Add Walph to existing project

    # Run Walph
    walph.sh plan                        # Generate implementation plan
    walph.sh build --max-iterations 10   # Build with limited iterations
    walph.sh status                      # Check current progress

WORKFLOW (new project):
    1. walph.sh init my-app       # Create project structure
    2. Edit specs/TEMPLATE.md     # Write your requirements
    3. walph.sh plan              # Generate task list
    4. walph.sh build             # Implement everything

WORKFLOW (existing project):
    1. cd my-existing-project
    2. walph.sh setup             # Add Walph config
    3. Edit AGENTS.md             # Add build/test commands
    4. Write specs in specs/      # Define what to build
    5. walph.sh plan              # Generate task list
    6. walph.sh build             # Implement everything

For more information, see README.md and QUICKSTART.md
EOF
}
