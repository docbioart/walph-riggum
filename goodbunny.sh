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
source "$SCRIPT_DIR/lib/runner.sh"

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
                if [[ $# -lt 2 ]]; then
                    log_error "--max-iterations requires a numeric argument"
                    show_gb_help
                    exit 1
                fi
                if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    log_error "--max-iterations must be a positive integer"
                    show_gb_help
                    exit 1
                fi
                MAX_ITERATIONS="$2"
                shift 2
                ;;
            --model)
                if [[ $# -lt 2 ]]; then
                    log_error "--model requires a model name argument"
                    show_gb_help
                    exit 1
                fi
                MODEL_OVERRIDE="$2"
                shift 2
                ;;
            --categories)
                if [[ $# -lt 2 ]]; then
                    log_error "--categories requires an argument"
                    show_gb_help
                    exit 1
                fi
                CATEGORIES_FILTER="$2"
                shift 2
                ;;
            --files)
                if [[ $# -lt 2 ]]; then
                    log_error "--files requires an argument"
                    show_gb_help
                    exit 1
                fi
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

    # Unset circuit breaker thresholds that were set by lib/config.sh
    # so we can apply goodbunny-specific defaults instead
    unset CIRCUIT_BREAKER_NO_CHANGE_THRESHOLD
    unset CIRCUIT_BREAKER_SAME_ERROR_THRESHOLD
    unset CIRCUIT_BREAKER_NO_COMMIT_THRESHOLD

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
                    GOODBUNNY_MODEL_AUDIT|GOODBUNNY_MODEL_FIX|GOODBUNNY_ITERATION_TIMEOUT|\
                    GOODBUNNY_CB_NO_CHANGE|GOODBUNNY_CB_SAME_ERROR|GOODBUNNY_CB_NO_COMMIT)
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
    # Priority: goodbunny-specific env var > config file > goodbunny defaults
    CIRCUIT_BREAKER_NO_CHANGE_THRESHOLD="${GOODBUNNY_CB_NO_CHANGE:-${CIRCUIT_BREAKER_NO_CHANGE_THRESHOLD:-$GB_DEFAULT_CB_NO_CHANGE}}"
    CIRCUIT_BREAKER_SAME_ERROR_THRESHOLD="${GOODBUNNY_CB_SAME_ERROR:-${CIRCUIT_BREAKER_SAME_ERROR_THRESHOLD:-$GB_DEFAULT_CB_SAME_ERROR}}"
    CIRCUIT_BREAKER_NO_COMMIT_THRESHOLD="${GOODBUNNY_CB_NO_COMMIT:-${CIRCUIT_BREAKER_NO_COMMIT_THRESHOLD:-$GB_DEFAULT_CB_NO_COMMIT}}"

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

# Callback for Good Bunny specific template substitutions
_gb_template_callback() {
    local full_prompt="$1"

    # Substitute categories and files sections using bash parameter expansion
    # This is safer than sed as it handles arbitrary content without needing escaping
    local categories_section
    categories_section=$(build_categories_section)
    full_prompt="${full_prompt//\{\{CATEGORIES\}\}/$categories_section}"

    local files_section
    files_section=$(build_files_section)
    full_prompt="${full_prompt//\{\{FILES\}\}/$files_section}"

    echo "$full_prompt"
}

# Callback for Good Bunny specific dry run information
_gb_dryrun_callback() {
    if [[ -n "$CATEGORIES_FILTER" ]]; then
        echo "  Categories: $CATEGORIES_FILTER"
    fi
    if [[ -n "$FILES_FILTER" ]]; then
        echo "  Files: $FILES_FILTER"
    fi
}

run_iteration() {
    local iteration="$1"
    local prompt_file="$2"
    local model="$3"

    # Call the shared iteration runner with Good Bunny specific callbacks
    run_shared_iteration "$iteration" "$prompt_file" "$model" "$GB_STATE_DIR" \
        "_gb_template_callback" "_gb_dryrun_callback"
}

# ============================================================================
# MAIN LOOP
# ============================================================================

main_loop() {
    # Use shared main loop implementation from lib/runner.sh
    run_main_loop "$GB_DIR" "$GB_STATE_DIR" "get_gb_model" "goodbunny"
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
