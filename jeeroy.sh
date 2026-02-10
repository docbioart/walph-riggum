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

# Source shared libraries
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/converter.sh"

# ============================================================================
# TEMP FILE CLEANUP
# ============================================================================

JEEROY_TEMP_FILES=""

cleanup_temp_files() {
    if [[ -n "$JEEROY_TEMP_FILES" ]]; then
        for f in $JEEROY_TEMP_FILES; do
            rm -f "$f" 2>/dev/null
        done
    fi
}

trap cleanup_temp_files EXIT INT TERM

# Create a tracked temp file
make_temp() {
    local tmp
    tmp=$(mktemp)
    JEEROY_TEMP_FILES="$JEEROY_TEMP_FILES $tmp"
    echo "$tmp"
}

# ============================================================================
# DEFAULTS AND ARGUMENT PARSING
# ============================================================================

DOCS_DIR=""
PROJECT_DIR=""
STACK=""
LFG_MODE=false
SKIP_QA=false
MODEL="opus"
DRY_RUN=false
VERBOSE=false

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
    --model <name>        Claude model to use (default: opus)
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
    PDF:            .pdf (pandoc or pdftotext)
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
                MODEL="$2"
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
    local missing=()

    if ! command_exists "claude"; then
        missing+=("claude (Claude CLI)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies:"
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        return 1
    fi

    # Check pandoc (warn but don't fail - some files may be .md/.txt only)
    if ! check_pandoc 2>/dev/null; then
        log_warn "pandoc not installed - only .md and .txt files will be processed"
        echo "  Install pandoc for docx/pptx/pdf/etc support"
    fi

    # Check chrome-devtools MCP (warn but don't fail - needed for UI testing)
    local chrome_mcp_found=false
    if [[ -f "${HOME}/.config/claude/claude_desktop_config.json" ]]; then
        if grep -q "chrome-devtools" "${HOME}/.config/claude/claude_desktop_config.json" 2>/dev/null; then
            chrome_mcp_found=true
        fi
    fi
    if [[ -f "${HOME}/Library/Application Support/Claude/claude_desktop_config.json" ]]; then
        if grep -q "chrome-devtools" "${HOME}/Library/Application Support/Claude/claude_desktop_config.json" 2>/dev/null; then
            chrome_mcp_found=true
        fi
    fi

    if [[ "$chrome_mcp_found" != "true" ]]; then
        log_warn "chrome-devtools MCP not found - UI testing will require manual verification"
        echo "  For automated UI testing, configure chrome-devtools MCP"
    fi

    return 0
}

# ============================================================================
# DOCUMENT PROCESSING
# ============================================================================

# Count supported files in the docs directory
count_supported_files() {
    local dir="$1"
    local count=0
    for file in "$dir"/*; do
        [[ -f "$file" ]] || continue
        if is_supported_file "$file"; then
            count=$((count + 1))
        fi
    done
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

# Load a prompt template file, returning its content on stdout
load_prompt_template() {
    local template_name="$1"
    local prompt_file="$SCRIPT_DIR/templates/$template_name"

    if [[ ! -f "$prompt_file" ]]; then
        log_error "Prompt template not found: $prompt_file"
        return 1
    fi

    cat "$prompt_file"
}

# ============================================================================
# ANALYSIS PHASE (Non-interactive)
# ============================================================================

run_analysis() {
    local converted_content="$1"

    log_info "Running document analysis..."

    local prompt
    prompt=$(load_prompt_template "PROMPT_jeeroy_analyze.md") || return 1

    # Write full prompt to temp file (avoids shell argument limits)
    local temp_prompt
    temp_prompt=$(make_temp)
    {
        printf '%s\n' "$prompt"
        printf '\n---\n\n# Documents to Analyze\n\n'
        printf '%s\n' "$converted_content"
    } > "$temp_prompt"

    local temp_output
    temp_output=$(make_temp)

    if cat "$temp_prompt" | claude -p \
        --model "$MODEL" \
        > "$temp_output" 2>&1; then
        cat "$temp_output"
    else
        log_error "Claude analysis failed"
        cat "$temp_output" >&2
        return 1
    fi
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
    {
        printf '%s\n' "$prompt"
        printf '\n---\n\n# Target Directory\n\n'
        printf 'Write all spec files to: %s/\n\n' "$specs_dir"
        printf '\n---\n\n# Analysis Results\n\n'
        printf '%s\n' "$analysis_output"
        printf '\n---\n\n# Original Documents\n\n'
        printf '%s\n' "$converted_content"
    } > "$context_file"

    # Run Claude interactively (NOT in print mode)
    # The initial prompt tells Claude to read the context and begin
    claude \
        --model "$MODEL" \
        --dangerously-skip-permissions \
        "Read the file at $context_file which contains project documentation and instructions for a Jeeroy Lenkins Q&A session. Follow those instructions: summarize what you found, ask clarifying questions ONE AT A TIME (waiting for my response each time), then write the spec files directly to $specs_dir/. Start now."

    # Clean up context file
    rm -f "$context_file"
}

# ============================================================================
# SKIP-QA MODE (Non-interactive spec generation)
# ============================================================================

run_direct_generation() {
    local converted_content="$1"
    local analysis_output="$2"

    log_info "Generating specs directly (skip-qa mode)..."

    local prompt
    prompt=$(load_prompt_template "PROMPT_jeeroy_qa.md") || return 1

    # Write full prompt to temp file
    local temp_prompt
    temp_prompt=$(make_temp)
    {
        printf '%s\n' "$prompt"
        printf '\n'
        printf '%s\n' "IMPORTANT: The user has requested --skip-qa mode. Do NOT ask any questions."
        printf '%s\n' "Go directly to generating spec files based on your best understanding of the documents."
        printf '%s\n' "Make reasonable assumptions where information is missing and note them in the specs."
        printf '\n---\n\n# Analysis Results\n\n'
        printf '%s\n' "$analysis_output"
        printf '\n---\n\n# Original Documents\n\n'
        printf '%s\n' "$converted_content"
    } > "$temp_prompt"

    local temp_output
    temp_output=$(make_temp)

    if cat "$temp_prompt" | claude -p \
        --model "$MODEL" \
        > "$temp_output" 2>&1; then
        cat "$temp_output"
    else
        log_error "Spec generation failed"
        cat "$temp_output" >&2
        return 1
    fi
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

    if [[ "$existing_specs" -gt 0 ]] && [[ "$LFG_MODE" != "true" ]]; then
        log_warn "specs/ directory already contains $existing_specs spec file(s)." >&2
        if ! ask_yes_no "Overwrite existing specs?"; then
            log_info "Keeping existing specs. New specs will be added alongside them." >&2
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
                write_spec_file "$specs_dir" "$current_filename" "$current_content"
                spec_count=$((spec_count + 1))
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
                write_spec_file "$specs_dir" "$current_filename" "$current_content"
                spec_count=$((spec_count + 1))
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
        write_spec_file "$specs_dir" "$current_filename" "$current_content"
        spec_count=$((spec_count + 1))
    fi

    echo "$spec_count"
}

# Write a single spec file
# All logging goes to stderr to not pollute stdout
write_spec_file() {
    local specs_dir="$1"
    local filename="$2"
    local content="$3"

    # Sanitize filename: strip path, keep only safe chars
    filename=$(basename "$filename")
    # Replace unsafe characters with hyphens
    filename=$(printf '%s' "$filename" | sed 's/[^a-zA-Z0-9._-]/-/g')

    # Ensure .md extension
    if [[ "$filename" != *.md ]]; then
        filename="${filename}.md"
    fi

    local filepath="$specs_dir/$filename"

    printf '%s\n' "$content" > "$filepath"
    log_success "Created spec: specs/$filename" >&2
}

# Parse the completion signal
parse_completion_signal() {
    local output="$1"

    local block
    block=$(printf '%s\n' "$output" | sed -n '/===JEEROY_COMPLETE===/,/===JEEROY_COMPLETE_END===/p')

    if [[ -z "$block" ]]; then
        return 1
    fi

    local specs_count
    specs_count=$(printf '%s\n' "$block" | grep "^specs_generated:" | sed 's/^specs_generated: *//')
    local project_type
    project_type=$(printf '%s\n' "$block" | grep "^project_type:" | sed 's/^project_type: *//')
    local stack
    stack=$(printf '%s\n' "$block" | grep "^stack:" | sed 's/^stack: *//')

    echo "$specs_count|$project_type|$stack"
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

    # Use provided stack or detected stack
    local stack_flag=""
    if [[ -n "$STACK" ]]; then
        stack_flag="--stack $STACK"
    elif [[ -n "$detected_stack" ]]; then
        stack_flag="--stack $detected_stack"
    fi

    # Step 1: Setup walph in the project
    if [[ ! -d "$PROJECT_DIR/.walph" ]]; then
        log_info "Step 1/3: Setting up Walph..."
        # shellcheck disable=SC2086
        (cd "$PROJECT_DIR" && "$walph_script" setup $stack_flag) || {
            log_error "Walph setup failed. Fix issues and run manually:"
            echo "  cd $PROJECT_DIR && walph setup"
            return 1
        }
    else
        log_info "Step 1/3: Walph already set up, skipping..."
    fi

    # Step 2: Run planning
    log_info "Step 2/3: Running Walph planning..."
    (cd "$PROJECT_DIR" && "$walph_script" plan --max-iterations 3) || {
        log_error "Walph planning failed. Fix issues and run manually:"
        echo "  cd $PROJECT_DIR && walph plan"
        return 1
    }

    # Step 3: Run building
    log_info "Step 3/3: Running Walph building..."
    (cd "$PROJECT_DIR" && "$walph_script" build) || {
        log_error "Walph building failed. Check logs and resume:"
        echo "  cd $PROJECT_DIR && walph build"
        return 1
    }

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
        log_info "[DRY RUN] Would convert $file_count files and analyze with Claude ($MODEL)"
        if [[ "$SKIP_QA" == "true" ]]; then echo "  Would skip Q&A and generate specs directly"; fi
        if [[ "$LFG_MODE" == "true" ]]; then echo "  Would chain into: walph setup -> plan -> build"; fi
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

    local analysis_output
    analysis_output=$(run_analysis "$converted_content")

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
        local generation_output
        generation_output=$(run_direct_generation "$converted_content" "$analysis_output")

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

    # ── Step 5: LFG pipeline (if enabled) ──────────────────────────────────

    if [[ "$LFG_MODE" == "true" ]]; then
        run_lfg_pipeline "$STACK"
    else
        log_info "Specs generated! Next steps:"
        echo "  1. Review specs in $specs_dir/"
        echo "  2. Run: walph setup   (if not already set up)"
        echo "  3. Run: walph plan"
        echo "  4. Run: walph build"
        echo ""
        echo "  Or run with --lfg to do it all automatically!"
    fi
}

main "$@"
