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
source "$SCRIPT_DIR/lib/harness.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/circuit_breaker.sh"
source "$SCRIPT_DIR/lib/status_parser.sh"
source "$SCRIPT_DIR/lib/spec_lint.sh"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/runner.sh"

# ============================================================================
# GOOD BUNNY DEFAULTS
# ============================================================================

GB_VERSION="1.0.0"

# Default configuration
GB_DEFAULT_MAX_ITERATIONS=30
# Model defaults are per harness — see harness_model_default in lib/harness.sh
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
MAX_ITERATIONS_OVERRIDE=""
MODEL_OVERRIDE=""
HARNESS_OVERRIDE=""
TIMEOUT_OVERRIDE=""
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
            analyze)
                MODE="analyze"
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
                MAX_ITERATIONS_OVERRIDE="$2"
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
            --harness)
                if [[ $# -lt 2 ]]; then
                    log_error "--harness requires a name: claude, codex, or opencode"
                    show_gb_help
                    exit 1
                fi
                HARNESS_OVERRIDE="$2"
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
            --timeout)
                if [[ $# -lt 2 ]]; then
                    log_error "--timeout requires a numeric argument (seconds)"
                    show_gb_help
                    exit 1
                fi
                if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    log_error "--timeout must be a positive integer (seconds)"
                    show_gb_help
                    exit 1
                fi
                TIMEOUT_OVERRIDE="$2"
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
        log_error "No command specified. Use 'audit', 'fix', or 'analyze'."
        show_gb_help
        exit 1
    fi
}

# ============================================================================
# CONFIGURATION
# ============================================================================

GB_CONFIG_KEYS='MAX_ITERATIONS|MODEL_AUDIT|MODEL_FIX|MODEL_ANALYZE|ITERATION_TIMEOUT|CIRCUIT_BREAKER_NO_CHANGE_THRESHOLD|CIRCUIT_BREAKER_SAME_ERROR_THRESHOLD|CIRCUIT_BREAKER_NO_COMMIT_THRESHOLD|HARNESS|REASONING_EFFORT|GOODBUNNY_MAX_ITERATIONS|GOODBUNNY_MODEL_AUDIT|GOODBUNNY_MODEL_FIX|GOODBUNNY_MODEL_ANALYZE|GOODBUNNY_ITERATION_TIMEOUT|GOODBUNNY_CB_NO_CHANGE|GOODBUNNY_CB_SAME_ERROR|GOODBUNNY_CB_NO_COMMIT'

load_goodbunny_config() {
    local project_config="$PROJECT_DIR/$GB_DIR/config"

    # Unset circuit breaker thresholds that were set by lib/config.sh
    # so we can apply goodbunny-specific defaults instead
    unset CIRCUIT_BREAKER_NO_CHANGE_THRESHOLD
    unset CIRCUIT_BREAKER_SAME_ERROR_THRESHOLD
    unset CIRCUIT_BREAKER_NO_COMMIT_THRESHOLD

    # Safe KEY=VALUE reader shared with Walph (never sources the file)
    load_config_file "$project_config" "$GB_CONFIG_KEYS"

    # Harness first: model defaults depend on it
    resolve_harness "${HARNESS_OVERRIDE:-}" "${GOODBUNNY_HARNESS:-}" "${HARNESS:-}" || return 1

    # Apply env var overrides → config file → defaults
    MAX_ITERATIONS="${GOODBUNNY_MAX_ITERATIONS:-${MAX_ITERATIONS:-$GB_DEFAULT_MAX_ITERATIONS}}"
    ITERATION_TIMEOUT="${GOODBUNNY_ITERATION_TIMEOUT:-${ITERATION_TIMEOUT:-$GB_DEFAULT_ITERATION_TIMEOUT}}"
    REASONING_EFFORT="${GOODBUNNY_REASONING_EFFORT:-${REASONING_EFFORT:-}}"

    harness_resolve_model MODEL_AUDIT   audit   "${GOODBUNNY_MODEL_AUDIT:-}"   || return 1
    harness_resolve_model MODEL_FIX     fix     "${GOODBUNNY_MODEL_FIX:-}"     || return 1
    harness_resolve_model MODEL_ANALYZE analyze "${GOODBUNNY_MODEL_ANALYZE:-}" || return 1

    # --model applies to this whole run; reject a Claude-only name on another harness
    if [[ -n "$MODEL_OVERRIDE" ]]; then
        # shellcheck disable=SC2034  # written through eval by harness_resolve_model
        local checked_override="$MODEL_OVERRIDE"
        harness_resolve_model checked_override "$MODE" "" "$MODEL_OVERRIDE" || return 1
    fi

    # CLI flag overrides (highest priority)
    if [[ -n "$MAX_ITERATIONS_OVERRIDE" ]]; then
        MAX_ITERATIONS="$MAX_ITERATIONS_OVERRIDE"
    fi
    if [[ -n "$TIMEOUT_OVERRIDE" ]]; then
        ITERATION_TIMEOUT="$TIMEOUT_OVERRIDE"
    fi
    if [[ -n "$MAX_ITERATIONS_OVERRIDE" ]]; then
        MAX_ITERATIONS="$MAX_ITERATIONS_OVERRIDE"
    fi

    # Circuit breaker thresholds (tighter than walph defaults)
    # Priority: goodbunny-specific env var > config file > goodbunny defaults
    CIRCUIT_BREAKER_NO_CHANGE_THRESHOLD="${GOODBUNNY_CB_NO_CHANGE:-${CIRCUIT_BREAKER_NO_CHANGE_THRESHOLD:-$GB_DEFAULT_CB_NO_CHANGE}}"
    CIRCUIT_BREAKER_SAME_ERROR_THRESHOLD="${GOODBUNNY_CB_SAME_ERROR:-${CIRCUIT_BREAKER_SAME_ERROR_THRESHOLD:-$GB_DEFAULT_CB_SAME_ERROR}}"
    CIRCUIT_BREAKER_NO_COMMIT_THRESHOLD="${GOODBUNNY_CB_NO_COMMIT:-${CIRCUIT_BREAKER_NO_COMMIT_THRESHOLD:-$GB_DEFAULT_CB_NO_COMMIT}}"

    # Set resume command for rate limit handler
    local harness_flag=""
    if [[ "$HARNESS" != "claude" ]]; then
        harness_flag=" --harness $HARNESS"
    fi
    export RESUME_COMMAND="goodbunny $MODE$harness_flag"

    # Shared engineering principles injected into prompts ({{PRINCIPLES}})
    if [[ -f "$PROJECT_DIR/$GB_DIR/PRINCIPLES.md" ]]; then
        PRINCIPLES_FILE="$PROJECT_DIR/$GB_DIR/PRINCIPLES.md"
    else
        PRINCIPLES_FILE="$SCRIPT_DIR/templates/PRINCIPLES.md"
    fi
    export PRINCIPLES_FILE

    # Ground truth for completion: in fix mode, don't trust the agent's
    # EXIT_SIGNAL while REVIEW_FINDINGS.md still has unchecked findings
    if [[ "$MODE" == "fix" ]] && [[ -f "$PROJECT_DIR/REVIEW_FINDINGS.md" ]]; then
        export COMPLETION_GROUND_TRUTH="$PROJECT_DIR/REVIEW_FINDINGS.md"
    else
        unset COMPLETION_GROUND_TRUTH
    fi
    return 0
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
        analyze)
            echo "$MODEL_ANALYZE"
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

# Agent CLI: claude (default), codex, or opencode. Also --harness / GOODBUNNY_HARNESS.
# HARNESS=claude

# Models per mode. Defaults depend on the harness:
#   claude:   audit=opus         fix=sonnet       analyze=opus
#   codex:    audit=gpt-6-astra  fix=gpt-5.6-sol  analyze=gpt-6-astra
#   opencode: whatever your opencode.json "model" says (use provider/model here)
# MODEL_AUDIT="opus"
# MODEL_FIX="sonnet"
# MODEL_ANALYZE="opus"

# Reasoning effort for harnesses that support it (codex: low..max, opencode: --variant)
# REASONING_EFFORT=high

# Iteration timeout in seconds (kills the agent if it hangs)
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

        # Check for codebase report
        if [[ -f "$PROJECT_DIR/GOODBUNNY_REPORT.md" ]]; then
            echo "Codebase report: Found"
            local sections_complete
            sections_complete=$(grep -c '^## [0-9]' "$PROJECT_DIR/GOODBUNNY_REPORT.md" 2>/dev/null || true)
            echo "Report sections: $sections_complete of 12"
            if [[ -f "$PROJECT_DIR/goodbunny.mermaid" ]]; then
                echo "Architecture diagram: Found (goodbunny.mermaid)"
            fi
        else
            echo "Codebase report: Not found (run 'goodbunny analyze')"
        fi

        # Check for review findings
        if [[ -f "$PROJECT_DIR/REVIEW_FINDINGS.md" ]]; then
            echo "Review findings: Found"
            local total_findings
            total_findings=$(grep -c '^\s*- \[ \]' "$PROJECT_DIR/REVIEW_FINDINGS.md" 2>/dev/null || true)
            local fixed_findings
            fixed_findings=$(grep -c '^\s*- \[x\]' "$PROJECT_DIR/REVIEW_FINDINGS.md" 2>/dev/null || true)
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
        rm -f "$PROJECT_DIR/$GB_STATE_DIR/last_iteration_note"
        rm -f "$PROJECT_DIR/$GB_STATE_DIR/completion_signal"
        rm -f "$PROJECT_DIR/$GB_STATE_DIR/stuck_signal"
        rm -f "$PROJECT_DIR/$GB_STATE_DIR/unverified_tasks"
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

    # Substitute audit findings reference (for analyze mode)
    local audit_ref
    if [[ -f "$PROJECT_DIR/REVIEW_FINDINGS.md" ]]; then
        audit_ref="- A prior audit exists in \`REVIEW_FINDINGS.md\`. Read it and incorporate relevant findings into this section."
    else
        audit_ref="- No prior audit found. Rely on TODO/FIXME scanning and your own analysis."
    fi
    full_prompt="${full_prompt//\{\{AUDIT_FINDINGS_REF\}\}/$audit_ref}"

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
    analyze           Document codebase (generates GOODBUNNY_REPORT.md)
    status            Show current review progress
    reset             Reset circuit breaker and state

OPTIONS:
    --max-iterations N    Maximum iterations (default: 30)
    --harness NAME        Agent CLI to run: claude (default), codex, opencode
    --model MODEL         Override model for this run (must fit the harness)
    --categories LIST     Comma-separated categories to review
                          (security,architecture,complexity,dry,kiss,
                           dependencies,error-handling,testing,
                           spec-compliance)
    --files PATH          Limit review to specific files or directories
    --timeout SECONDS     Iteration timeout in seconds (default: 900)
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
    goodbunny.sh analyze                              # Document entire codebase
    goodbunny.sh analyze --files lib/                 # Document specific directory
    goodbunny.sh status                               # Check progress
EOF
}

show_gb_howto() {
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════════════════╗
║                              GOOD BUNNY                                       ║
║                     Autonomous Code Quality Reviewer                          ║
╚═══════════════════════════════════════════════════════════════════════════════╝

Good Bunny audits any project for code quality issues and fixes them
autonomously. No setup required — just point it at your project.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 QUICK START
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  cd your-project

  goodbunny audit                    # Deep code review → REVIEW_FINDINGS.md
  goodbunny fix                      # Fix findings one by one
  goodbunny analyze                  # Document codebase → GOODBUNNY_REPORT.md

  That's it. No setup, no config files, no ceremony.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 HOW IT WORKS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  1. AUDIT (Opus)        Good Bunny reads your project and reviews it
                         against 9 code quality categories.
                         Generates REVIEW_FINDINGS.md with prioritized issues.

  2. FIX (Sonnet)        Good Bunny picks ONE finding per iteration:
                         - Reads the finding
                         - Applies the fix
                         - Runs tests
                         - Marks finding done [x]
                         - Commits changes
                         - Repeats until all findings are fixed

  3. ANALYZE (Opus)      Good Bunny documents your codebase:
                         - Writes 1-2 sections per iteration
                         - 12-section comprehensive report
                         - Incorporates audit findings if available
                         - Generates GOODBUNNY_REPORT.md

  4. CIRCUIT BREAKER     Auto-stops if stuck:
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
  Spec Compliance   Implementation vs specs/ acceptance criteria
                    (only for projects with specs, e.g. Walph-built)

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

  goodbunny analyze [options]        Document the codebase
    --files src/                     Scope to specific paths
    --model opus                     Override model

  goodbunny status                   Show review progress
  goodbunny reset                    Reset circuit breaker (if stuck)

  Any command accepts --harness claude|codex|opencode (default: claude).
  Codex defaults to gpt-6-astra for audit/analyze and gpt-5.6-sol for fix;
  OpenCode uses the model configured in your opencode.json.

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

    # Load configuration (resolves the harness, then harness-aware model defaults)
    load_goodbunny_config || exit 1

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
    log_info "Harness: $(harness_display_name) ($HARNESS)"
    warn_if_not_git_repo
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

    # One loop per project (see lib/utils.sh acquire_run_lock). The EXIT
    # trap must keep the runner's temp-file cleanup.
    acquire_run_lock "$PROJECT_DIR/$GB_STATE_DIR/goodbunny.lock" "goodbunny"
    trap 'release_run_lock; cleanup_runner_temp_files' EXIT

    # Run main loop (capture the status without tripping errexit)
    local exit_code=0
    main_loop || exit_code=$?

    # Summary
    echo ""
    log_info "Session complete"
    show_gb_status

    exit $exit_code
}

# Run main
main "$@"
