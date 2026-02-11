#!/usr/bin/env bash
# Good Bunny - Autonomous Code Quality Reviewer
# A companion tool to Walph Riggum that audits and fixes code quality issues
# on any project. No setup required.

set -euo pipefail

# ============================================================================
# SCRIPT SETUP
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(pwd)"

# Set tool identity BEFORE sourcing shared libs (they use these for display)
export LOG_PREFIX="GOODBUNNY"
export LOG_FILE_PREFIX="goodbunny"
export TOOL_NAME="Good Bunny"

# Source library files
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/circuit_breaker.sh"
source "$SCRIPT_DIR/lib/status_parser.sh"
source "$SCRIPT_DIR/lib/utils.sh"

# ============================================================================
# GOOD BUNNY DEFAULTS
# ============================================================================

GB_VERSION="1.0.0"

# Default configuration
GB_DEFAULT_MAX_ITERATIONS=30
GB_DEFAULT_MODEL_AUDIT="opus"
GB_DEFAULT_MODEL_FIX="sonnet"
GB_DEFAULT_ITERATION_TIMEOUT=900
GB_DEFAULT_CB_NO_CHANGE=3
GB_DEFAULT_CB_SAME_ERROR=3
GB_DEFAULT_CB_NO_COMMIT=4

# State directories (relative to project)
GB_DIR=".goodbunny"
GB_LOG_DIR="$GB_DIR/logs"
GB_STATE_DIR="$GB_DIR/state"

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

MODE=""
MAX_ITERATIONS=""
MODEL_OVERRIDE=""
DRY_RUN=false
VERBOSE=false
CATEGORIES_FILTER=""
FILES_FILTER=""

parse_args() {
    # No arguments — show help
    if [[ $# -eq 0 ]]; then
        show_gb_howto
        exit 0
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            audit)
                MODE="audit"
                shift
                ;;
            fix)
                MODE="fix"
                shift
                ;;
            status)
                show_gb_status
                exit 0
                ;;
            reset)
                reset_gb_state
                exit 0
                ;;
            --max-iterations)
                MAX_ITERATIONS="$2"
                shift 2
                ;;
            --model)
                MODEL_OVERRIDE="$2"
                shift 2
                ;;
            --categories)
                CATEGORIES_FILTER="$2"
                shift 2
                ;;
            --files)
                FILES_FILTER="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                WALPH_VERBOSE=true
                shift
                ;;
            -h|--help)
                show_gb_help
                exit 0
                ;;
            --version)
                echo "Good Bunny v${GB_VERSION}"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_gb_help
                exit 1
                ;;
        esac
    done

    if [[ -z "$MODE" ]]; then
        log_error "No command specified. Use 'audit' or 'fix'."
        show_gb_help
        exit 1
    fi
}

# ============================================================================
# CONFIGURATION
# ============================================================================

load_goodbunny_config() {
    local project_config="$PROJECT_DIR/$GB_DIR/config"

    # Load from config file if it exists (safely parse as key=value)
    if [[ -f "$project_config" ]]; then
        # Read config file line by line, validate format, and set variables
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Skip empty lines and comments
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

            # Validate line matches KEY=VALUE pattern (only uppercase letters, numbers, underscores in key)
            if [[ "$line" =~ ^[A-Z_][A-Z0-9_]*=(.*)$ ]]; then
                # Extract key and value
                local key="${line%%=*}"
                local value="${line#*=}"

                # Only allow known configuration variables
                case "$key" in
                    MAX_ITERATIONS|MODEL_AUDIT|MODEL_FIX|ITERATION_TIMEOUT|\
                    CIRCUIT_BREAKER_NO_CHANGE_THRESHOLD|CIRCUIT_BREAKER_SAME_ERROR_THRESHOLD|\
                    CIRCUIT_BREAKER_NO_COMMIT_THRESHOLD|GOODBUNNY_MAX_ITERATIONS|\
                    GOODBUNNY_MODEL_AUDIT|GOODBUNNY_MODEL_FIX|GOODBUNNY_ITERATION_TIMEOUT)
                        # Safe assignment using eval with proper quoting
                        eval "$key=\"\$value\""
                        ;;
                esac
            fi
        done < "$project_config"
    fi

    # Apply env var overrides → config file → defaults
    MAX_ITERATIONS="${GOODBUNNY_MAX_ITERATIONS:-${MAX_ITERATIONS:-$GB_DEFAULT_MAX_ITERATIONS}}"
    MODEL_AUDIT="${GOODBUNNY_MODEL_AUDIT:-${MODEL_AUDIT:-$GB_DEFAULT_MODEL_AUDIT}}"
    MODEL_FIX="${GOODBUNNY_MODEL_FIX:-${MODEL_FIX:-$GB_DEFAULT_MODEL_FIX}}"
    ITERATION_TIMEOUT="${GOODBUNNY_ITERATION_TIMEOUT:-${ITERATION_TIMEOUT:-$GB_DEFAULT_ITERATION_TIMEOUT}}"

    # Circuit breaker thresholds (tighter than walph defaults)
    CIRCUIT_BREAKER_NO_CHANGE_THRESHOLD="${CIRCUIT_BREAKER_NO_CHANGE_THRESHOLD:-$GB_DEFAULT_CB_NO_CHANGE}"
    CIRCUIT_BREAKER_SAME_ERROR_THRESHOLD="${CIRCUIT_BREAKER_SAME_ERROR_THRESHOLD:-$GB_DEFAULT_CB_SAME_ERROR}"
    CIRCUIT_BREAKER_NO_COMMIT_THRESHOLD="${CIRCUIT_BREAKER_NO_COMMIT_THRESHOLD:-$GB_DEFAULT_CB_NO_COMMIT}"

    # Set resume command for rate limit handler
    export RESUME_COMMAND="goodbunny $MODE"
}

# Get the model for the current mode
get_gb_model() {
    local mode="$1"
    case "$mode" in
        audit)
            echo "$MODEL_AUDIT"
            ;;
        fix)
            echo "$MODEL_FIX"
            ;;
        *)
            echo "$MODEL_FIX"
            ;;
    esac
}

# ============================================================================
# DIRECTORY MANAGEMENT
# ============================================================================

ensure_goodbunny_dirs() {
    # Auto-create .goodbunny/ on first run (no setup command needed)
    if [[ ! -d "$PROJECT_DIR/$GB_DIR" ]]; then
        log_info "First run — creating $GB_DIR/ directory"
        mkdir -p "$PROJECT_DIR/$GB_LOG_DIR"
        mkdir -p "$PROJECT_DIR/$GB_STATE_DIR"

        # Create default config
        cat > "$PROJECT_DIR/$GB_DIR/config" << 'EOF'
# Good Bunny Configuration
# Uncomment and modify as needed

# Maximum iterations before stopping
# MAX_ITERATIONS=30

# Models (use aliases: opus, sonnet, or full model names)
# MODEL_AUDIT="opus"
# MODEL_FIX="sonnet"

# Iteration timeout in seconds (kills Claude if it hangs)
# ITERATION_TIMEOUT=900

# Circuit breaker thresholds
# CIRCUIT_BREAKER_NO_CHANGE_THRESHOLD=3
# CIRCUIT_BREAKER_SAME_ERROR_THRESHOLD=3
# CIRCUIT_BREAKER_NO_COMMIT_THRESHOLD=4
EOF
    else
        # Ensure subdirectories exist
        mkdir -p "$PROJECT_DIR/$GB_LOG_DIR"
        mkdir -p "$PROJECT_DIR/$GB_STATE_DIR"
    fi

    # Add to .gitignore if it exists and doesn't already have our entries
    if [[ -f "$PROJECT_DIR/.gitignore" ]]; then
        if ! grep -q ".goodbunny/logs/" "$PROJECT_DIR/.gitignore" 2>/dev/null; then
            log_info "Adding Good Bunny entries to .gitignore"
            echo "" >> "$PROJECT_DIR/.gitignore"
            echo "# Good Bunny" >> "$PROJECT_DIR/.gitignore"
            echo ".goodbunny/logs/" >> "$PROJECT_DIR/.gitignore"
            echo ".goodbunny/state/" >> "$PROJECT_DIR/.gitignore"
        fi
    fi
}

# ============================================================================
# STATUS AND RESET
# ============================================================================

show_gb_status() {
    echo "Good Bunny Status"
    echo "=================="
    echo ""
    echo "Project: $PROJECT_DIR"

    if [[ -d "$PROJECT_DIR/$GB_DIR" ]]; then
        echo "Good Bunny initialized: Yes"

        # Circuit breaker status
        if [[ -f "$PROJECT_DIR/$GB_STATE_DIR/circuit_breaker.json" ]]; then
            init_circuit_breaker "$PROJECT_DIR/$GB_STATE_DIR"
            echo "Circuit breaker: $(get_circuit_breaker_status)"
        fi

        # Check for review findings
        if [[ -f "$PROJECT_DIR/REVIEW_FINDINGS.md" ]]; then
            echo "Review findings: Found"
            local total_findings
            total_findings=$(grep -c '^\s*- \[ \]' "$PROJECT_DIR/REVIEW_FINDINGS.md" 2>/dev/null || echo "0")
            local fixed_findings
            fixed_findings=$(grep -c '^\s*- \[x\]' "$PROJECT_DIR/REVIEW_FINDINGS.md" 2>/dev/null || echo "0")
            echo "Findings: $fixed_findings fixed, $total_findings remaining"
        else
            echo "Review findings: Not found (run 'goodbunny audit' first)"
        fi
    else
        echo "Good Bunny initialized: No (will auto-create on first run)"
    fi
}

reset_gb_state() {
    log_info "Resetting Good Bunny state..."

    if [[ -d "$PROJECT_DIR/$GB_STATE_DIR" ]]; then
        rm -f "$PROJECT_DIR/$GB_STATE_DIR/"*.json
        log_success "State reset complete"
    else
        log_warn "No state directory found"
    fi
}

# ============================================================================
# PROMPT CONSTRUCTION
# ============================================================================

build_categories_section() {
    if [[ -n "$CATEGORIES_FILTER" ]]; then
        echo "**Reviewing only these categories:** ${CATEGORIES_FILTER}. Skip categories not listed."
    else
        echo "Review all applicable categories below."
    fi
}

build_files_section() {
    if [[ -n "$FILES_FILTER" ]]; then
        echo "**Reviewing only these files/directories:** ${FILES_FILTER}. Ignore files outside this scope."
    else
        echo "Review the entire project."
    fi
}

# ============================================================================
# ITERATION RUNNER
# ============================================================================

run_iteration() {
    local iteration="$1"
    local prompt_file="$2"
    local model="$3"

    log_iteration_start "$iteration" "$MAX_ITERATIONS" "$MODE"

    # Build the prompt
    local full_prompt=""

    if [[ -f "$prompt_file" ]]; then
        full_prompt=$(cat "$prompt_file")
    else
        log_error "Prompt file not found: $prompt_file"
        return 1
    fi

    # Substitute template variables
    full_prompt=$(echo "$full_prompt" | sed "s/{{ITERATION}}/$iteration/g")
    full_prompt=$(echo "$full_prompt" | sed "s/{{MAX_ITERATIONS}}/$MAX_ITERATIONS/g")
    full_prompt=$(echo "$full_prompt" | sed "s/{{MODE}}/$MODE/g")

    # Substitute categories and files sections
    local categories_section
    categories_section=$(build_categories_section)
    # Escape sed special characters in replacement string
    local escaped_categories
    escaped_categories=$(printf '%s\n' "$categories_section" | sed 's/[&/\]/\\&/g')
    full_prompt=$(echo "$full_prompt" | sed "s/{{CATEGORIES}}/$escaped_categories/g")

    local files_section
    files_section=$(build_files_section)
    local escaped_files
    escaped_files=$(printf '%s\n' "$files_section" | sed 's/[&/\]/\\&/g')
    full_prompt=$(echo "$full_prompt" | sed "s/{{FILES}}/$escaped_files/g")

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run Claude with:"
        echo "  Model: $model"
        echo "  Prompt file: $prompt_file"
        echo "  Mode: $MODE"
        if [[ -n "$CATEGORIES_FILTER" ]]; then
            echo "  Categories: $CATEGORIES_FILTER"
        fi
        if [[ -n "$FILES_FILTER" ]]; then
            echo "  Files: $FILES_FILTER"
        fi
        echo ""
        echo "  Prompt preview (first 20 lines):"
        echo "$full_prompt" | head -20 | sed 's/^/    /'
        echo "    ..."
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

    # Run Claude in the background with a timeout watchdog
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
            sleep 2
            kill -9 "$claude_pid" 2>/dev/null
            wait "$claude_pid" 2>/dev/null
            exit_code=124
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

    # Stream output to terminal
    cat "$temp_output"
    output=$(cat "$temp_output")
    rm -f "$temp_output"

    # Handle timeout
    if [[ $exit_code -eq 124 ]]; then
        log_error "Iteration timed out after ${timeout}s"
        log_info "Claude may have stalled. The next iteration will retry."
        log_info "Adjust ITERATION_TIMEOUT in $GB_DIR/config if needed."
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
        touch "$PROJECT_DIR/$GB_STATE_DIR/completion_signal"
        return 0
    fi

    return "$exit_code"
}

# ============================================================================
# MAIN LOOP
# ============================================================================

main_loop() {
    local iteration=1

    while [[ $iteration -le $MAX_ITERATIONS ]]; do
        # Check circuit breaker before iteration
        if circuit_breaker_triggered; then
            log_error "Circuit breaker triggered — stopping loop"
            log_info "Run 'goodbunny reset' to clear the circuit breaker"
            return 1
        fi

        # Select prompt file
        local prompt_file
        if [[ -f "$PROJECT_DIR/$GB_DIR/PROMPT_${MODE}.md" ]]; then
            prompt_file="$PROJECT_DIR/$GB_DIR/PROMPT_${MODE}.md"
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
            model=$(get_gb_model "$MODE")
        fi

        # Export mode for circuit breaker
        export TOOL_MODE="$MODE"

        # Run iteration
        WALPH_CURRENT_ITERATION="$iteration"
        local result
        if run_iteration "$iteration" "$prompt_file" "$model"; then
            log_success "Iteration $iteration completed successfully"
        else
            result=$?
            if [[ $result -eq 2 ]]; then
                log_info "Exit requested by user"
                return 0
            fi
            log_warn "Iteration $iteration completed with issues"
        fi

        # Check for completion signal file
        if [[ -f "$PROJECT_DIR/$GB_STATE_DIR/completion_signal" ]]; then
            log_success "All work completed!"
            rm -f "$PROJECT_DIR/$GB_STATE_DIR/completion_signal"
            return 0
        fi

        ((iteration++))

        # Small delay between iterations
        sleep 1
    done

    log_warn "Maximum iterations ($MAX_ITERATIONS) reached"
    return 0
}

# ============================================================================
# HELP AND HOWTO
# ============================================================================

show_gb_help() {
    cat << 'EOF'
Good Bunny - Autonomous Code Quality Reviewer

USAGE:
    goodbunny.sh <command> [options]

COMMANDS:
    audit             Deep code review (generates REVIEW_FINDINGS.md)
    fix               Fix findings one at a time (from REVIEW_FINDINGS.md)
    status            Show current review progress
    reset             Reset circuit breaker and state

OPTIONS:
    --max-iterations N    Maximum iterations (default: 30)
    --model MODEL         Override model for this run
    --categories LIST     Comma-separated categories to review
                          (security,architecture,complexity,dry,kiss,
                           dependencies,error-handling,testing)
    --files PATH          Limit review to specific files or directories
    --dry-run             Show what would be run without executing
    -v, --verbose         Enable verbose output
    -h, --help            Show this help message
    --version             Show version

EXAMPLES:
    goodbunny.sh audit                                # Full audit
    goodbunny.sh audit --categories security,testing  # Focused audit
    goodbunny.sh audit --files src/                   # Audit specific directory
    goodbunny.sh fix                                  # Fix findings one by one
    goodbunny.sh fix --max-iterations 5               # Fix up to 5 findings
    goodbunny.sh status                               # Check progress
EOF
}

show_gb_howto() {
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════════════════╗
║                           GOOD BUNNY                                         ║
║                  Autonomous Code Quality Reviewer                            ║
╚═══════════════════════════════════════════════════════════════════════════════╝

Good Bunny audits any project for code quality issues and fixes them
autonomously. No setup required — just point it at your project.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 QUICK START
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  cd your-project

  goodbunny audit                    # Deep code review → REVIEW_FINDINGS.md
  goodbunny fix                      # Fix findings one by one

  That's it. No setup, no config files, no ceremony.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 HOW IT WORKS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  1. AUDIT (Opus)        Good Bunny reads your project and reviews it
                         against 8 code quality categories.
                         Generates REVIEW_FINDINGS.md with prioritized issues.

  2. FIX (Sonnet)        Good Bunny picks ONE finding per iteration:
                         - Reads the finding
                         - Applies the fix
                         - Runs tests
                         - Marks finding done [x]
                         - Commits changes
                         - Repeats until all findings are fixed

  3. CIRCUIT BREAKER     Auto-stops if stuck:
                         - No file changes for 3 iterations
                         - Same error 3 times
                         - No commits for 4 iterations

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 REVIEW CATEGORIES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Security          OWASP Top 10, hardcoded secrets, injection, auth
  Architecture      SRP, god modules, circular deps, coupling
  Complexity        Long functions, deep nesting, complex booleans
  DRY               Duplicated code, copy-paste patterns
  KISS              Over-engineering, unnecessary abstraction
  Dependencies      Outdated/vulnerable packages, unused deps
  Error Handling    Missing catches, swallowed errors, validation
  Testing           Missing tests, coverage gaps, brittle tests

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 COMMANDS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  goodbunny audit [options]          Deep code review
    --categories security,testing    Review only specific categories
    --files src/                     Review only specific paths
    --model opus                     Override model

  goodbunny fix [options]            Fix findings one by one
    --max-iterations 10              Limit number of fixes
    --model sonnet                   Override model

  goodbunny status                   Show review progress
  goodbunny reset                    Reset circuit breaker (if stuck)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 TIPS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  • Works on any project — no AGENTS.md or specs needed
  • Review REVIEW_FINDINGS.md after audit — remove false positives before fix
  • Use --categories to focus on what matters most
  • Use --files to audit specific parts of a large codebase
  • If stuck — goodbunny reset, then review findings for clarity

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 MORE INFO
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  goodbunny --help        Full command reference
  See: README.md

EOF
}

# ============================================================================
# INITIALIZATION AND MAIN
# ============================================================================

init_goodbunny() {
    # Ensure .goodbunny/ exists (auto-create on first run)
    ensure_goodbunny_dirs

    # Load configuration
    load_goodbunny_config

    # Apply command line override for max iterations
    if [[ -n "${MAX_ITERATIONS:-}" ]]; then
        : # Already set from parse_args or load_goodbunny_config
    else
        MAX_ITERATIONS="$GB_DEFAULT_MAX_ITERATIONS"
    fi

    # Check dependencies
    if ! check_dependencies; then
        exit 1
    fi

    # Initialize logging
    local session_id
    session_id=$(generate_session_id)
    init_logging "$PROJECT_DIR/$GB_LOG_DIR" "$session_id"

    # Initialize circuit breaker
    init_circuit_breaker "$PROJECT_DIR/$GB_STATE_DIR"

    log_info "Good Bunny starting"
    log_info "Mode: $MODE"
    log_info "Max iterations: $MAX_ITERATIONS"
    if [[ -n "$CATEGORIES_FILTER" ]]; then
        log_info "Categories: $CATEGORIES_FILTER"
    fi
    if [[ -n "$FILES_FILTER" ]]; then
        log_info "Files: $FILES_FILTER"
    fi
    log_debug "Project directory: $PROJECT_DIR"
    log_debug "Script directory: $SCRIPT_DIR"
}

main() {
    parse_args "$@"

    init_goodbunny

    # Run main loop
    main_loop
    local exit_code=$?

    # Summary
    echo ""
    log_info "Session complete"
    show_gb_status

    exit $exit_code
}

# Run main
main "$@"
