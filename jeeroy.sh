#!/usr/bin/env bash
# Jeeroy Lenkins - Document-to-Spec Converter
# Companion tool for Walph Riggum
#
# Reads project documentation in any format, analyzes it with Claude,
# asks clarifying questions, and generates Walph-compatible spec files.
#
# "At least I have chicken." - Jeeroy Lenkins

set -euo pipefail

# ============================================================================
# SCRIPT SETUP
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set tool identity BEFORE sourcing shared libs (they use these for display)
export LOG_PREFIX="JEEROY"
export LOG_FILE_PREFIX="jeeroy"
export TOOL_NAME="Jeeroy Lenkins"

# Source shared libraries
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/harness.sh"
source "$SCRIPT_DIR/lib/converter.sh"
source "$SCRIPT_DIR/lib/status_parser.sh"
source "$SCRIPT_DIR/lib/spec_lint.sh"
source "$SCRIPT_DIR/lib/plan_review.sh"   # parse_reviewer_spec / check_reviewer_ready only

# ============================================================================
# TEMP FILE CLEANUP
# ============================================================================

# Arrays (not space-joined strings): a project dir with spaces would
# word-split in the cleanup loop and rm the wrong path
JEEROY_TEMP_FILES=()

cleanup_temp_files() {
    if [[ ${#JEEROY_TEMP_FILES[@]} -gt 0 ]]; then
        rm -f -- "${JEEROY_TEMP_FILES[@]}" 2>/dev/null || true
        JEEROY_TEMP_FILES=()
    fi
    if declare -f harness_cleanup_scratch > /dev/null 2>&1; then
        harness_cleanup_scratch
    fi
}

_jeeroy_on_signal() {
    echo ""
    log_warn "Interrupted — stopping the running agent"
    harness_kill_current
    cleanup_temp_files
    exit 130
}

trap cleanup_temp_files EXIT
trap _jeeroy_on_signal INT TERM

# Create a tracked temp file and store its path in the named variable
# (a $(...) capture would register the file in a subshell and lose it)
# Usage: make_temp temp_prompt
make_temp() {
    local var_name="$1"
    local tmp
    tmp=$(mktemp)
    JEEROY_TEMP_FILES+=("$tmp")
    eval "$var_name=\"\$tmp\""
}

# Track an existing path for cleanup (e.g. the Q&A context file)
track_temp_file() {
    JEEROY_TEMP_FILES+=("$1")
}

# ============================================================================
# DEFAULTS AND ARGUMENT PARSING
# ============================================================================

DOCS_DIR=""
PROJECT_DIR=""
STACK=""
LFG_MODE=false
SKIP_QA=false
MODEL=""                 # resolved per harness in validate_environment
MODEL_FLAG=""            # --model
HARNESS_OVERRIDE=""      # --harness
REVIEWER=""              # --reviewer, passed through to walph plan in --lfg
FAST_MODE=false
DRY_RUN=false
VERBOSE=false
JEEROY_TIMEOUT="${JEEROY_TIMEOUT:-1800}"   # seconds per non-interactive agent call

JEEROY_VERSION="1.0.0"

show_jeeroy_help() {
    cat << 'EOF'
Jeeroy Lenkins - Document-to-Spec Converter
Companion tool for Walph Riggum

USAGE:
    jeeroy.sh <docs-directory> [options]

DESCRIPTION:
    Reads project documentation (docx, pdf, md, txt, pptx, etc.),
    analyzes it with Claude, asks clarifying questions, and generates
    Walph Riggum-compatible spec files.

ARGUMENTS:
    docs-directory        Directory containing project documentation

OPTIONS:
    --project <path>      Target project directory (default: current directory)
    --stack <type>        Stack hint: node, python, swift, kotlin, go, rust
    --lfg                 "Let's F***ing Go" - auto-chain into walph
                          (setup -> plan -> build, fully autonomous)
    --skip-qa             Skip interactive Q&A, generate best-effort specs
    --harness <name>      Agent CLI: claude (default), codex, or opencode
    --model <name>        Model to use (default per harness: claude=opus,
                          codex=gpt-6-astra, opencode=your opencode.json model)
    --reviewer <spec>     With --lfg: have a second model review the plan before
                          building, e.g. --reviewer codex:gpt-6-astra
    --fast                Claude fast mode (2.5x faster, higher cost; Claude only)
    --dry-run             Show what would happen without executing
    -v, --verbose         Verbose output
    -h, --help            Show this help
    --version             Show version

EXAMPLES:
    # Analyze docs and generate specs interactively
    jeeroy.sh ./client-docs

    # Target a specific project directory
    jeeroy.sh ./client-docs --project ./my-new-api --stack node

    # Full autonomous mode: analyze -> specs -> setup -> plan -> build
    jeeroy.sh ./client-docs --project ./my-new-api --lfg

    # Quick and dirty: skip questions, just send it
    jeeroy.sh ./client-docs --skip-qa --lfg

SUPPORTED FORMATS:
    Direct read:    .md, .txt
    Via pandoc:     .docx, .doc, .pptx, .ppt, .rtf, .html, .odt, .epub
    PDF:            .pdf (pdftotext — brew install poppler)
    Images:         .jpg, .jpeg, .png, .gif, .webp, .svg (file reference)
    Code/Config:    .js, .ts, .py, .rb, .go, .rs, .json, .yaml, etc.
    Archives:       .zip (extract and process contents)

WORKFLOW:
    1. Reads all documents in the provided directory
    2. Converts them to markdown (via pandoc if needed)
    3. Sends content to Claude for analysis (identifies features, gaps)
    4. Claude asks clarifying questions interactively (unless --skip-qa)
    5. Generates spec files in project/specs/
    6. If --lfg: automatically runs walph setup -> plan -> build
       (with --reviewer, a second model reviews the plan between plan and build)

EOF
}

parse_jeeroy_args() {
    if [[ $# -eq 0 ]]; then
        show_jeeroy_help
        exit 0
    fi

    # Check for help/version first
    for arg in "$@"; do
        case "$arg" in
            -h|--help)
                show_jeeroy_help
                exit 0
                ;;
            --version)
                echo "Jeeroy Lenkins v${JEEROY_VERSION}"
                exit 0
                ;;
        esac
    done

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project)
                if [[ $# -lt 2 ]]; then
                    log_error "--project requires a path argument"
                    exit 1
                fi
                PROJECT_DIR="$2"
                shift 2
                ;;
            --stack)
                if [[ $# -lt 2 ]]; then
                    log_error "--stack requires a type argument"
                    exit 1
                fi
                STACK="$2"
                shift 2
                ;;
            --lfg)
                LFG_MODE=true
                shift
                ;;
            --skip-qa)
                SKIP_QA=true
                shift
                ;;
            --model)
                if [[ $# -lt 2 ]]; then
                    log_error "--model requires a name argument"
                    exit 1
                fi
                MODEL_FLAG="$2"
                shift 2
                ;;
            --harness)
                if [[ $# -lt 2 ]]; then
                    log_error "--harness requires a name: claude, codex, or opencode"
                    exit 1
                fi
                HARNESS_OVERRIDE="$2"
                shift 2
                ;;
            --reviewer)
                if [[ $# -lt 2 ]]; then
                    log_error "--reviewer requires <harness>[:<model>], e.g. codex:gpt-6-astra"
                    exit 1
                fi
                REVIEWER="$2"
                shift 2
                ;;
            --fast)
                FAST_MODE=true
                shift
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
            -*)
                log_error "Unknown option: $1"
                show_jeeroy_help
                exit 1
                ;;
            *)
                # First positional argument is the docs directory
                if [[ -z "$DOCS_DIR" ]]; then
                    DOCS_DIR="$1"
                fi
                shift
                ;;
        esac
    done

    # Validate docs directory
    if [[ -z "$DOCS_DIR" ]]; then
        log_error "No documents directory specified."
        echo "Usage: jeeroy.sh <docs-directory> [options]"
        exit 1
    fi

    # Resolve to absolute path
    DOCS_DIR=$(cd "$DOCS_DIR" 2>/dev/null && pwd || echo "$DOCS_DIR")

    if [[ ! -d "$DOCS_DIR" ]]; then
        log_error "Documents directory not found: $DOCS_DIR"
        exit 1
    fi

    # Default project directory to current directory
    if [[ -z "$PROJECT_DIR" ]]; then
        PROJECT_DIR="$(pwd)"
    else
        # Resolve to absolute path, create if needed
        if [[ ! -d "$PROJECT_DIR" ]]; then
            if [[ "$LFG_MODE" == "true" ]]; then
                mkdir -p "$PROJECT_DIR"
            else
                if ask_yes_no "Project directory '$PROJECT_DIR' doesn't exist. Create it?"; then
                    mkdir -p "$PROJECT_DIR"
                else
                    exit 1
                fi
            fi
        fi
        PROJECT_DIR=$(cd "$PROJECT_DIR" && pwd)
    fi
}

# ============================================================================
# VALIDATION
# ============================================================================

validate_environment() {
    # Harness: --harness > JEEROY_HARNESS > claude
    resolve_harness "$HARNESS_OVERRIDE" "${JEEROY_HARNESS:-}" "" || return 1

    local missing=()
    if ! harness_check_installed "$HARNESS"; then
        missing+=("$HARNESS (agent CLI)")
    fi
    if ! command_exists "jq"; then
        missing+=("jq (used to parse the agent's JSON output)")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies:"
        local dep
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        return 1
    fi

    # Model: --model > JEEROY_MODEL > harness default for planning-grade work
    harness_resolve_model MODEL plan "${JEEROY_MODEL:-}" "$MODEL_FLAG" || return 1

    if [[ "$FAST_MODE" == "true" ]] && [[ "$HARNESS" != "claude" ]]; then
        log_warn "--fast is a Claude Code setting; ignored for $HARNESS"
        FAST_MODE=false
    fi

    # A plan reviewer only matters with --lfg, but a bad spec should fail now
    if [[ -n "$REVIEWER" ]]; then
        if [[ "$LFG_MODE" != "true" ]]; then
            log_warn "--reviewer only applies with --lfg (it reviews the plan before building)"
        fi
        check_reviewer_ready "$REVIEWER" || return 1
    fi

    # Check pandoc (warn but don't fail - some files may be .md/.txt only)
    if ! check_pandoc 2>/dev/null; then
        log_warn "pandoc not installed - only .md and .txt files will be processed"
        echo "  Install pandoc for docx/pptx/html/etc support"
    fi

    # Check pdftotext separately: pandoc cannot read PDFs, so without
    # pdftotext every PDF silently becomes '[could not be converted]'
    if ! check_pdftotext 2>/dev/null; then
        log_warn "pdftotext not installed - PDF files cannot be converted"
        echo "  Install it for PDF support: brew install poppler"
    fi

    # Check chrome-devtools MCP for the selected harness (warn but don't fail)
    if ! check_chrome_mcp "$HARNESS"; then
        log_warn "chrome-devtools MCP not found in the $HARNESS config - UI testing will require manual verification"
        echo "  For automated UI testing, configure the chrome-devtools MCP server in $(harness_display_name)"
    fi

    return 0
}

# ============================================================================
# DOCUMENT PROCESSING
# ============================================================================

# Count supported files in the docs directory.
# Uses find (like convert_directory does) so the count and the conversion
# agree on dotfiles — a glob would skip hidden files the converter processes.
count_supported_files() {
    local dir="$1"
    local count=0
    local file
    while IFS= read -r -d '' file; do
        if is_supported_file "$file"; then
            count=$((count + 1))
        fi
    done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null)
    echo "$count"
}

# Estimate token count (rough: 1 token ~ 4 chars)
estimate_tokens() {
    local content="$1"
    local chars=${#content}
    echo $(( chars / 4 ))
}

# ============================================================================
# PROMPT LOADING
# ============================================================================

# Load a prompt template file, returning its content on stdout.
# Substitutes {{PRINCIPLES}} with the shared engineering principles.
load_prompt_template() {
    local template_name="$1"
    local prompt_file="$SCRIPT_DIR/templates/$template_name"

    if [[ ! -f "$prompt_file" ]]; then
        log_error "Prompt template not found: $prompt_file"
        return 1
    fi

    local content
    content=$(cat "$prompt_file")

    if [[ "$content" == *"{{PRINCIPLES}}"* ]]; then
        local principles=""
        if [[ -f "$SCRIPT_DIR/templates/PRINCIPLES.md" ]]; then
            principles=$(cat "$SCRIPT_DIR/templates/PRINCIPLES.md")
        else
            log_warn "Shared principles file not found: $SCRIPT_DIR/templates/PRINCIPLES.md"
        fi
        content=$(substitute_placeholder "$content" "{{PRINCIPLES}}" "$principles")
    fi

    printf '%s\n' "$content"
}

# ============================================================================
# ANALYSIS PHASE (Non-interactive)
# ============================================================================

# Result of the last run_restricted_call (and of run_analysis /
# run_direct_generation, which end in one)
JEEROY_RESULT=""

# Run one non-interactive, restricted (no edits/commands) agent call with the
# given prompt file. Stores the final response in JEEROY_RESULT. Returns 1 on
# any failure after logging it (rate limits get the standard resume hint).
#
# Call it directly, never inside $(...): in a subshell the agent's PID and the
# temp files are registered where the signal handler and the EXIT trap cannot
# see them, so Ctrl-C would leave the agent running with nothing to stop it.
run_restricted_call() {
    local prompt_file="$1"
    local what="$2"

    JEEROY_RESULT=""
    local temp_output temp_err temp_final
    make_temp temp_output
    make_temp temp_err
    make_temp temp_final

    local exit_code=0
    harness_exec "$MODEL" restricted "$prompt_file" "$temp_output" "$temp_err" "$temp_final" "$JEEROY_TIMEOUT" || exit_code=$?
    harness_parse_result "$temp_output" "$temp_err" "$temp_final"

    if check_rate_limit "$HARNESS_ERRORS"; then
        log_error "Rate limit hit during $what" >&2
        log_info "The $(harness_display_name) API rate limit was reached. Please wait a few minutes and try again." >&2
        log_info "You can resume by running: jeeroy [same arguments]" >&2
        return 1
    fi
    if [[ $exit_code -eq 124 ]]; then
        log_error "$(harness_display_name) timed out after ${JEEROY_TIMEOUT}s during $what (set JEEROY_TIMEOUT to raise it)" >&2
        return 1
    fi
    if [[ $exit_code -ne 0 ]] || [[ "$HARNESS_TEXT_OK" != "true" ]]; then
        log_error "$(harness_display_name) failed during $what (exit code $exit_code)" >&2
        if [[ -n "$HARNESS_ERRORS" ]]; then
            printf '%s\n' "$HARNESS_ERRORS" | head -5 >&2
        else
            tail -20 "$temp_output" >&2
            tail -5 "$temp_err" >&2
        fi
        return 1
    fi

    log_debug "$what: $(harness_usage_summary)" >&2
    JEEROY_RESULT="$HARNESS_TEXT"
    return 0
}

run_analysis() {
    local converted_content="$1"

    log_info "Running document analysis with $(harness_display_name) (${MODEL:-harness default})..."

    local prompt
    prompt=$(load_prompt_template "PROMPT_jeeroy_analyze.md") || return 1

    # Write full prompt to temp file (avoids shell argument limits)
    local temp_prompt
    make_temp temp_prompt
    {
        printf '%s\n' "$prompt"
        printf '\n---\n\n# Documents to Analyze\n\n'
        printf '%s\n' "$converted_content"
    } > "$temp_prompt"

    run_restricted_call "$temp_prompt" "analysis"
}

# Extract the analysis block from Claude's output
extract_analysis_block() {
    local output="$1"
    printf '%s\n' "$output" | sed -n '/===ANALYSIS===/,/===ANALYSIS_END===/p'
}

# Parse a field from the analysis block
parse_analysis_field() {
    local block="$1"
    local field="$2"
    printf '%s\n' "$block" | grep "^${field}:" | head -1 | sed "s/^${field}: *//"
}

# ============================================================================
# Q&A PHASE (Interactive)
# ============================================================================

run_qa_session() {
    local converted_content="$1"
    local analysis_output="$2"
    local specs_dir="$3"

    log_info "Starting interactive Q&A session..."
    log_info "Claude will ask clarifying questions. Answer them, or type 'skip' to proceed."
    echo ""

    local prompt
    prompt=$(load_prompt_template "PROMPT_jeeroy_qa.md") || return 1

    # Write full context to a file Claude can read
    local context_file="$PROJECT_DIR/.jeeroy_context.md"
    # Track temp file for cleanup on interrupt
    track_temp_file "$context_file"
    {
        printf '%s\n' "$prompt"
        printf '\n---\n\n# Target Directory\n\n'
        printf 'Write all spec files to: %s/\n\n' "$specs_dir"
        printf '\n---\n\n# Analysis Results\n\n'
        printf '%s\n' "$analysis_output"
        printf '\n---\n\n# Original Documents\n\n'
        printf '%s\n' "$converted_content"
    } > "$context_file"

    # Run the agent interactively (NOT in print mode). The initial prompt
    # tells it to read the context file and begin. The session needs write
    # access to create the spec files, so it runs with full access.
    harness_interactive_cmd "$MODEL" \
        "Read the file at $context_file which contains project documentation and instructions for a Jeeroy Lenkins Q&A session. Follow those instructions: summarize what you found, ask clarifying questions ONE AT A TIME (waiting for my response each time), then write the spec files directly to $specs_dir/. Start now." || return 1
    log_info "Starting $(harness_display_name) interactively (${MODEL:-harness default})..."
    (cd "$PROJECT_DIR" && env ${HARNESS_ENV[@]+"${HARNESS_ENV[@]}"} "${HARNESS_CMD[@]}") || \
        log_warn "$(harness_display_name) exited with a non-zero status; checking for specs anyway"

    # Clean up context file
    rm -f "$context_file"
}

# ============================================================================
# SKIP-QA MODE (Non-interactive spec generation)
# ============================================================================

run_direct_generation() {
    local converted_content="$1"
    local analysis_output="$2"

    log_info "Generating specs directly (skip-qa mode) with $(harness_display_name) (${MODEL:-harness default})..."

    local prompt
    prompt=$(load_prompt_template "PROMPT_jeeroy_qa.md") || return 1

    # Write full prompt to temp file
    local temp_prompt
    make_temp temp_prompt
    {
        printf '%s\n' "$prompt"
        printf '\n'
        printf '%s\n' "IMPORTANT: The user has requested --skip-qa mode. Do NOT ask any questions."
        printf '%s\n' "Go directly to generating spec files based on your best understanding of the documents."
        printf '%s\n' "Make reasonable assumptions where information is missing and note them in the specs."
        printf '%s\n' ""
        printf '%s\n' "IMPORTANT: In this mode you CANNOT write files to disk. Instead, output every spec file"
        printf '%s\n' "in your response using EXACTLY this delimited format (one block per spec file):"
        printf '%s\n' ""
        printf '%s\n' "===SPEC_FILE: kebab-case-filename.md==="
        printf '%s\n' "[complete markdown content of the spec]"
        printf '%s\n' "===SPEC_FILE_END==="
        printf '\n---\n\n# Analysis Results\n\n'
        printf '%s\n' "$analysis_output"
        printf '\n---\n\n# Original Documents\n\n'
        printf '%s\n' "$converted_content"
    } > "$temp_prompt"

    run_restricted_call "$temp_prompt" "spec generation"
}

# ============================================================================
# SPEC FILE EXTRACTION
# ============================================================================

# Extract spec files from Claude's output and write them to disk
# Echoes the number of specs written to stdout
extract_and_write_specs() {
    local output="$1"
    local specs_dir="$2"
    local spec_count=0

    mkdir -p "$specs_dir"

    # Check if specs directory already has files
    local existing_specs
    existing_specs=$(find "$specs_dir" -maxdepth 1 -name "*.md" -not -name "README.md" -not -name "TEMPLATE.md" 2>/dev/null | wc -l | tr -d ' ')

    local keep_existing=false
    if [[ "$existing_specs" -gt 0 ]] && [[ "$LFG_MODE" != "true" ]]; then
        log_warn "specs/ directory already contains $existing_specs spec file(s)." >&2
        if ! ask_yes_no "Overwrite existing specs?"; then
            log_info "Keeping existing specs — new specs with colliding filenames will be skipped." >&2
            keep_existing=true
        fi
    fi

    # Parse spec files from the delimited output
    local in_spec=false
    local current_filename=""
    local current_content=""

    while IFS= read -r line; do
        # Check for spec file start
        if [[ "$line" =~ ^===SPEC_FILE:\ (.+)=== ]]; then
            # If we were already in a spec, write the previous one
            if [[ "$in_spec" == "true" ]] && [[ -n "$current_filename" ]]; then
                WRITE_SPEC_SKIPPED=false
                write_spec_file "$specs_dir" "$current_filename" "$current_content" "$keep_existing"
                [[ "$WRITE_SPEC_SKIPPED" == "true" ]] || spec_count=$((spec_count + 1))
            fi

            current_filename="${BASH_REMATCH[1]}"
            # Trim whitespace from filename using sed (portable)
            current_filename=$(printf '%s' "$current_filename" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            current_content=""
            in_spec=true
            continue
        fi

        # Check for spec file end
        if [[ "$line" == "===SPEC_FILE_END===" ]]; then
            if [[ "$in_spec" == "true" ]] && [[ -n "$current_filename" ]]; then
                WRITE_SPEC_SKIPPED=false
                write_spec_file "$specs_dir" "$current_filename" "$current_content" "$keep_existing"
                [[ "$WRITE_SPEC_SKIPPED" == "true" ]] || spec_count=$((spec_count + 1))
            fi
            in_spec=false
            current_filename=""
            current_content=""
            continue
        fi

        # Accumulate content if inside a spec
        if [[ "$in_spec" == "true" ]]; then
            if [[ -z "$current_content" ]]; then
                current_content="$line"
            else
                current_content="$current_content
$line"
            fi
        fi
    done <<< "$output"

    # Handle case where last spec wasn't closed with END marker
    if [[ "$in_spec" == "true" ]] && [[ -n "$current_filename" ]]; then
        WRITE_SPEC_SKIPPED=false
        write_spec_file "$specs_dir" "$current_filename" "$current_content" "$keep_existing"
        [[ "$WRITE_SPEC_SKIPPED" == "true" ]] || spec_count=$((spec_count + 1))
    fi

    echo "$spec_count"
}

# Write a single spec file
# All logging goes to stderr to not pollute stdout
write_spec_file() {
    local specs_dir="$1"
    local filename="$2"
    local content="$3"
    local keep_existing="${4:-false}"

    # Sanitize filename: strip path, keep only safe chars
    filename=$(basename "$filename")
    # Replace unsafe characters with hyphens
    filename=$(printf '%s' "$filename" | sed 's/[^a-zA-Z0-9._-]/-/g')

    # Ensure .md extension
    if [[ "$filename" != *.md ]]; then
        filename="${filename}.md"
    fi

    local filepath="$specs_dir/$filename"

    # Honor the user's "don't overwrite" answer: keep their file, skip ours
    if [[ "$keep_existing" == "true" ]] && [[ -f "$filepath" ]]; then
        log_warn "Kept existing spec (skipped generated one): specs/$filename" >&2
        WRITE_SPEC_SKIPPED=true
        return 0
    fi

    printf '%s\n' "$content" > "$filepath"
    log_success "Created spec: specs/$filename" >&2
}

# ============================================================================
# LFG PIPELINE
# ============================================================================

run_lfg_pipeline() {
    local detected_stack="$1"

    echo ""
    echo "${CYAN}╔════════════════════════════════════════════════════════════╗${RESET}"
    echo "${CYAN}║${RESET} ${BOLD}JEEROY LENKINS: LFG MODE${RESET}                                  ${CYAN}║${RESET}"
    echo "${CYAN}║${RESET} Hold my beer...                                             ${CYAN}║${RESET}"
    echo "${CYAN}╚════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    local walph_script="$SCRIPT_DIR/walph.sh"

    if [[ ! -f "$walph_script" ]]; then
        log_error "walph.sh not found at: $walph_script"
        return 1
    fi

    # Use provided stack or detected stack. The detected value comes from
    # Claude's free-text analysis — validate it's a single clean token before
    # turning it into a CLI flag ("node + react" would word-split into bogus
    # setup arguments and abort the pipeline).
    local stack_args=()
    local stack_choice=""
    if [[ -n "$STACK" ]]; then
        stack_choice="$STACK"
    elif [[ -n "$detected_stack" ]]; then
        stack_choice="$detected_stack"
    fi
    if [[ -n "$stack_choice" ]]; then
        if [[ "$stack_choice" =~ ^[a-z][a-z0-9+-]*$ ]]; then
            stack_args=(--stack "$stack_choice")
        else
            log_warn "Ignoring unusable stack suggestion '$stack_choice' — walph setup will auto-detect"
        fi
    fi

    # Step 1: Setup walph in the project
    if [[ ! -d "$PROJECT_DIR/.walph" ]]; then
        log_info "Step 1/3: Setting up Walph..."
        # WALPH_SETUP_INLINE suppresses the next-steps banner — the pipeline
        # continues into plan/build immediately
        (cd "$PROJECT_DIR" && WALPH_SETUP_INLINE=true "$walph_script" setup ${stack_args[@]+"${stack_args[@]}"}) || {
            log_error "Walph setup failed. Fix issues and run manually:"
            echo "  cd $PROJECT_DIR && walph setup"
            return 1
        }
    else
        log_info "Step 1/3: Walph already set up, skipping..."
    fi

    # Harness/model choices follow into Walph
    local harness_args=(--harness "$HARNESS")
    local reviewer_args=()
    if [[ -n "$REVIEWER" ]]; then
        reviewer_args=(--reviewer "$REVIEWER")
    fi

    # Step 2: Run planning (with the optional second-model review). If a
    # review was requested and did not complete, walph plan exits non-zero
    # and we must not start an autonomous build on an unreviewed plan.
    log_info "Step 2/3: Running Walph planning..."
    (cd "$PROJECT_DIR" && "$walph_script" plan --max-iterations 3 "${harness_args[@]}" ${reviewer_args[@]+"${reviewer_args[@]}"}) || {
        log_error "Walph planning (or its plan review) did not complete. Fix issues and run manually:"
        echo "  cd $PROJECT_DIR && walph plan --harness $HARNESS${REVIEWER:+ --reviewer $REVIEWER}"
        return 1
    }

    # Gate: planning must have actually produced tasks before we commit to a
    # potentially long autonomous build
    local plan_file="$PROJECT_DIR/IMPLEMENTATION_PLAN.md"
    if [[ ! -f "$plan_file" ]] || ! grep -qE '^[[:space:]]*- \[[ x]\]' "$plan_file"; then
        log_error "Planning did not produce any tasks in IMPLEMENTATION_PLAN.md — not starting a build"
        echo "  Check specs/ for clarity, then run: cd $PROJECT_DIR && walph plan"
        return 1
    fi

    # Optional human gate: a 30-second plan review is the cheapest quality
    # check in the pipeline. Skipped with --skip-qa or when non-interactive.
    if [[ "$SKIP_QA" != "true" ]] && [[ -t 0 ]]; then
        local task_count
        task_count=$(grep -cE '^[[:space:]]*- \[ \]' "$plan_file" 2>/dev/null) || task_count=0
        echo ""
        log_info "Plan generated with $task_count open task(s). First tasks:"
        grep -E '^[[:space:]]*- \[ \]' "$plan_file" | head -15 | sed 's/^/  /'
        if [[ "$task_count" -gt 15 ]]; then
            echo "  ... and $((task_count - 15)) more (see IMPLEMENTATION_PLAN.md)"
        fi
        echo ""
        if ! ask_yes_no "Proceed to build with this plan?"; then
            log_info "Edit IMPLEMENTATION_PLAN.md as needed, then run:"
            echo "  cd $PROJECT_DIR && walph build"
            return 0
        fi
    fi

    # Step 3: Run building
    log_info "Step 3/3: Running Walph building..."
    local build_rc=0
    (cd "$PROJECT_DIR" && "$walph_script" build "${harness_args[@]}") || build_rc=$?
    if [[ $build_rc -eq 3 ]]; then
        # walph's "ended without completing" code: max iterations reached or
        # verification left failing criteria — NOT a finished pipeline
        log_warn "Build ended without completing — unfinished tasks remain in IMPLEMENTATION_PLAN.md."
        echo "  Resume with: cd $PROJECT_DIR && walph build --harness $HARNESS"
        echo "  (After timeouts, 'walph recover --harness $HARNESS' rebuilds just the interrupted tasks.)"
        return 1
    elif [[ $build_rc -ne 0 ]]; then
        log_error "Walph building failed. Check logs and resume:"
        echo "  cd $PROJECT_DIR && walph build --harness $HARNESS"
        return 1
    fi

    # Ground truth check before declaring victory: the plan's checkboxes,
    # not walph's exit code, decide whether the pipeline is done
    if grep -qE '^[[:space:]]*- \[ \]' "$plan_file"; then
        log_warn "Build exited cleanly but unchecked tasks remain in IMPLEMENTATION_PLAN.md — not declaring the pipeline complete."
        echo "  Resume with: cd $PROJECT_DIR && walph build"
        return 1
    fi

    log_success "LFG pipeline complete!"
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    parse_jeeroy_args "$@"

    echo ""
    echo "${CYAN}╔════════════════════════════════════════════════════════════╗${RESET}"
    echo "${CYAN}║${RESET} ${BOLD}JEEROY LENKINS${RESET}                                              ${CYAN}║${RESET}"
    echo "${CYAN}║${RESET} Document-to-Spec Converter for Walph Riggum                ${CYAN}║${RESET}"
    echo "${CYAN}╚════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    # Validate environment
    if ! validate_environment; then
        exit 1
    fi

    # Show what we found
    log_info "Documents directory: $DOCS_DIR"
    log_info "Target project: $PROJECT_DIR"
    log_info "Harness: $(harness_display_name) ($HARNESS), model: ${MODEL:-harness default}"
    if [[ -n "$STACK" ]]; then log_info "Stack hint: $STACK"; fi
    if [[ "$LFG_MODE" == "true" ]]; then log_info "LFG mode: ENGAGED"; fi
    if [[ "$SKIP_QA" == "true" ]]; then log_info "Skip Q&A: Yes"; fi
    echo ""

    # Show file summary
    get_conversion_summary "$DOCS_DIR"
    echo ""

    local file_count
    file_count=$(count_supported_files "$DOCS_DIR")

    if [[ "$file_count" -eq 0 ]]; then
        log_error "No supported files found in: $DOCS_DIR"
        log_info "Supported formats: $(get_supported_extensions_display)"
        exit 1
    fi

    log_info "Found $file_count supported file(s)"

    # Dry run stops here
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would convert $file_count files and analyze with $(harness_display_name) (${MODEL:-harness default})"
        harness_build_cmd "$MODEL" restricted "<final-message-file>" || exit 1
        echo "  Command: $(harness_cmd_string) < <prompt>"
        if [[ "$SKIP_QA" == "true" ]]; then echo "  Would skip Q&A and generate specs directly"; fi
        if [[ "$LFG_MODE" == "true" ]]; then echo "  Would chain into: walph setup -> plan${REVIEWER:+ -> review-plan ($REVIEWER)} -> build (--harness $HARNESS)"; fi
        exit 0
    fi

    # ── Step 1: Convert documents ──────────────────────────────────────────

    log_info "Converting documents to markdown..."
    local converted_content
    converted_content=$(convert_directory "$DOCS_DIR")

    if [[ -z "$converted_content" ]]; then
        log_error "No content extracted from documents"
        exit 1
    fi

    # Warn about large content
    local token_estimate
    token_estimate=$(estimate_tokens "$converted_content")
    if [[ $token_estimate -gt 100000 ]]; then
        log_warn "Document content is very large (~${token_estimate} tokens)"
        log_warn "This may exceed context limits. Consider splitting into smaller batches."
        if [[ "$LFG_MODE" != "true" ]]; then
            if ! ask_yes_no "Continue anyway?"; then
                exit 0
            fi
        fi
    fi

    log_debug "Converted content: ~${token_estimate} estimated tokens"

    # ── Step 2: Analysis phase ─────────────────────────────────────────────

    # || capture: without it, run_analysis returning 1 (e.g. rate limit)
    # would kill the script via set -e before any error message is shown
    local analysis_output=""
    run_analysis "$converted_content" && analysis_output="$JEEROY_RESULT" || {
        log_error "Analysis failed — see the message above"
        exit 1
    }

    if [[ -z "$analysis_output" ]]; then
        log_error "Analysis produced no output"
        exit 1
    fi

    # Extract structured analysis
    local analysis_block
    analysis_block=$(extract_analysis_block "$analysis_output")

    if [[ -n "$analysis_block" ]]; then
        local detected_type
        detected_type=$(parse_analysis_field "$analysis_block" "project_type")
        local detected_stack
        detected_stack=$(parse_analysis_field "$analysis_block" "stack_suggestion")
        local feature_count
        feature_count=$(parse_analysis_field "$analysis_block" "feature_count")

        log_success "Analysis complete"
        if [[ -n "$detected_type" ]]; then log_info "Project type: $detected_type"; fi
        if [[ -n "$detected_stack" ]]; then log_info "Suggested stack: $detected_stack"; fi
        if [[ -n "$feature_count" ]]; then log_info "Features identified: $feature_count"; fi

        # Use detected stack if none provided
        if [[ -z "$STACK" ]] && [[ -n "$detected_stack" ]]; then
            STACK="$detected_stack"
        fi
    else
        log_warn "Could not parse structured analysis (will continue with raw output)"
    fi

    # ── Step 3: Q&A or direct generation ───────────────────────────────────

    local specs_dir="$PROJECT_DIR/specs"
    mkdir -p "$specs_dir"

    if [[ "$SKIP_QA" == "true" ]]; then
        # Non-interactive: Claude outputs with delimiters, we parse and write
        local generation_output=""
        run_direct_generation "$converted_content" "$analysis_output" && generation_output="$JEEROY_RESULT" || {
            log_error "Spec generation failed — see the message above"
            exit 1
        }

        if [[ -z "$generation_output" ]]; then
            log_error "Spec generation produced no output"
            exit 1
        fi

        # Extract and write spec files from delimited output
        local parsed_count
        parsed_count=$(extract_and_write_specs "$generation_output" "$specs_dir")

        if [[ "$parsed_count" -eq 0 ]]; then
            log_warn "No spec files were extracted from Claude's output"
            log_info "The raw output has been saved. You may need to manually create specs."

            # Save raw output for debugging
            local raw_output_file="$PROJECT_DIR/jeeroy_raw_output.md"
            printf '%s\n' "$generation_output" > "$raw_output_file"
            log_info "Raw output saved to: $raw_output_file"
            exit 1
        fi
    else
        # Interactive: Claude writes specs directly to disk during the session
        run_qa_session "$converted_content" "$analysis_output" "$specs_dir"
    fi

    # ── Step 4: Count generated spec files ─────────────────────────────────

    local spec_count
    spec_count=$(find "$specs_dir" -maxdepth 1 -name "*.md" -not -name "README.md" -not -name "TEMPLATE.md" 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$spec_count" -eq 0 ]]; then
        log_warn "No spec files found in $specs_dir/"
        log_info "You may need to manually create specs or run again."
        exit 1
    fi

    echo ""
    log_success "Generated $spec_count spec file(s) in $specs_dir/"
    echo ""

    # List generated specs
    for spec_file in "$specs_dir"/*.md; do
        [[ -f "$spec_file" ]] || continue
        local fname
        fname=$(basename "$spec_file")
        [[ "$fname" == "README.md" ]] && continue
        [[ "$fname" == "TEMPLATE.md" ]] && continue
        echo "  - specs/$fname"
    done
    echo ""

    # Structural check: malformed specs burn build iterations downstream
    log_info "Checking generated specs for structural issues..."
    if lint_specs "$specs_dir"; then
        log_success "Specs look structurally sound"
    else
        log_warn "Some specs are missing sections Walph relies on (requirements, acceptance criteria, examples)"
        log_warn "Review and improve them in $specs_dir/ before (or during) the build"
    fi
    echo ""

    # ── Step 5: LFG pipeline (if enabled) ──────────────────────────────────

    if [[ "$LFG_MODE" == "true" ]]; then
        run_lfg_pipeline "$STACK"
    else
        log_info "Specs generated! Next steps:"
        echo "  1. Review specs in $specs_dir/"
        echo "  2. Run: walph setup   (if not already set up)"
        echo "  3. Run: walph plan --harness $HARNESS"
        echo "  4. Run: walph build --harness $HARNESS"
        echo ""
        echo "  Or run with --lfg to do it all automatically!"
    fi
}

main "$@"
