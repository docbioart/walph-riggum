#!/usr/bin/env bash

# Setup command logic for Walph Riggum
# Extracted from walph.sh to improve modularity

parse_setup_args() {
    # Check for help first
    for arg in "$@"; do
        if [[ "$arg" == "-h" ]] || [[ "$arg" == "--help" ]]; then
            show_setup_help
            exit 0
        fi
    done

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stack)
                SETUP_STACK="$2"
                shift 2
                ;;
            --force|-f)
                SETUP_FORCE=true
                shift
                ;;
            -*)
                log_error "Unknown setup option: $1"
                show_setup_help
                exit 1
                ;;
            *)
                shift
                ;;
        esac
    done
}

show_setup_help() {
    cat << 'EOF'
Walph Riggum - Setup Existing Project

USAGE:
    walph.sh setup [options]

DESCRIPTION:
    Adds Walph configuration to an existing project directory.
    Run this command from within your project root.

OPTIONS:
    --stack <type>        Language stack: node, python, swift, kotlin
                          (auto-detected if not specified)
    -f, --force           Overwrite existing Walph files
    -h, --help            Show this help

WHAT IT CREATES:
    .walph/               # Configuration directory
      ├── logs/           # Session logs
      ├── state/          # Circuit breaker state
      ├── config          # Configuration overrides
      ├── PROMPT_plan.md  # Planning prompt (customizable)
      └── PROMPT_build.md # Building prompt (customizable)
    specs/                # Your requirements (if not exists)
    AGENTS.md             # Build/test commands (if not exists)
    IMPLEMENTATION_PLAN.md # Task list (if not exists)

EXAMPLES:
    # Auto-detect stack and setup
    cd my-existing-project
    walph setup

    # Specify stack explicitly
    walph setup --stack python

    # Overwrite existing Walph files
    walph setup --force

AFTER SETUP:
    1. Edit AGENTS.md with your build/test commands
    2. Write specs in specs/
    3. Run: walph plan
    4. Run: walph build
EOF
}

detect_stack() {
    local dir="${1:-.}"

    # Check for package.json (Node.js)
    if [[ -f "$dir/package.json" ]]; then
        echo "node"
        return
    fi

    # Check for Python indicators
    if [[ -f "$dir/requirements.txt" ]] || [[ -f "$dir/setup.py" ]] || [[ -f "$dir/pyproject.toml" ]] || [[ -f "$dir/Pipfile" ]]; then
        echo "python"
        return
    fi

    # Check for Swift indicators
    if [[ -f "$dir/Package.swift" ]] || ls "$dir"/*.xcodeproj 1>/dev/null 2>&1 || ls "$dir"/*.xcworkspace 1>/dev/null 2>&1; then
        echo "swift"
        return
    fi

    # Check for Kotlin/Android indicators
    if [[ -f "$dir/build.gradle" ]] || [[ -f "$dir/build.gradle.kts" ]] || [[ -d "$dir/app/src/main/java" ]]; then
        echo "kotlin"
        return
    fi

    # Check for Go
    if [[ -f "$dir/go.mod" ]]; then
        echo "go"
        return
    fi

    # Check for Rust
    if [[ -f "$dir/Cargo.toml" ]]; then
        echo "rust"
        return
    fi

    # Default to node
    echo "node"
}

run_setup() {
    local target_dir
    target_dir="$(pwd)"
    local project_name
    project_name=$(basename "$target_dir")

    log_info "Setting up Walph in existing project: $project_name"

    # Check if already set up
    if [[ -d "$target_dir/.walph" ]] && [[ "$SETUP_FORCE" != "true" ]]; then
        log_warn "Project already has .walph directory."
        log_info "Use --force to overwrite existing configuration."
        exit 1
    fi

    # Detect stack if not specified
    local stack="$SETUP_STACK"
    if [[ -z "$stack" ]]; then
        stack=$(detect_stack "$target_dir")
        log_info "Auto-detected stack: $stack"
    fi

    # Create .walph directory structure
    log_info "Creating .walph directory..."
    mkdir -p "$target_dir/.walph/logs"
    mkdir -p "$target_dir/.walph/state"

    # Copy prompt templates
    if [[ -f "$SCRIPT_DIR/templates/PROMPT_plan.md" ]]; then
        cp "$SCRIPT_DIR/templates/PROMPT_plan.md" "$target_dir/.walph/"
    fi
    if [[ -f "$SCRIPT_DIR/templates/PROMPT_build.md" ]]; then
        cp "$SCRIPT_DIR/templates/PROMPT_build.md" "$target_dir/.walph/"
    fi

    # Create config file
    cat > "$target_dir/.walph/config" << 'EOF'
# Walph Riggum Configuration
# Uncomment and modify as needed

# Maximum iterations before stopping
# MAX_ITERATIONS=50

# Models (use aliases: opus, sonnet, or full model names)
# MODEL_PLAN="opus"
# MODEL_BUILD="sonnet"

# Circuit breaker thresholds
# CIRCUIT_BREAKER_NO_CHANGE_THRESHOLD=3
# CIRCUIT_BREAKER_SAME_ERROR_THRESHOLD=5
# CIRCUIT_BREAKER_NO_COMMIT_THRESHOLD=5
EOF

    # Create specs directory if it doesn't exist
    if [[ ! -d "$target_dir/specs" ]]; then
        log_info "Creating specs directory..."
        mkdir -p "$target_dir/specs"

        # Add spec template
        cat > "$target_dir/specs/TEMPLATE.md" << 'EOF'
# Feature: [Feature Name]

## Overview

[1-2 sentences: What are we building and why?]

## Requirements

### Must Have

1. [Specific, testable requirement]
2. [Specific, testable requirement]

## Technical Details

### Files to Modify/Create

- `[path/to/file]` - [What changes]

## Acceptance Criteria

- [ ] [Criterion 1]
- [ ] All tests pass
EOF
    else
        log_info "specs/ directory already exists - keeping existing files"
    fi

    # Create AGENTS.md if it doesn't exist (or if force)
    if [[ ! -f "$target_dir/AGENTS.md" ]] || [[ "$SETUP_FORCE" == "true" ]]; then
        log_info "Creating AGENTS.md..."
        # Call shared function in basic mode (no template)
        create_agents_md "$target_dir" "$stack"
    else
        log_info "AGENTS.md already exists - keeping existing file"
    fi

    # Create IMPLEMENTATION_PLAN.md if it doesn't exist
    if [[ ! -f "$target_dir/IMPLEMENTATION_PLAN.md" ]]; then
        log_info "Creating IMPLEMENTATION_PLAN.md..."
        cat > "$target_dir/IMPLEMENTATION_PLAN.md" << 'EOF'
# Implementation Plan

> Generated by `walph plan`. Write your specs in `specs/` first.

## Overview

<!-- Will be filled by walph plan -->

## Tasks

<!-- Tasks will appear here as checkboxes -->

Run `walph plan` to generate tasks from your specs.
EOF
    else
        log_info "IMPLEMENTATION_PLAN.md already exists - keeping existing file"
    fi

    # Add to .gitignore if it exists
    if [[ -f "$target_dir/.gitignore" ]]; then
        if ! grep -q ".walph/logs/" "$target_dir/.gitignore" 2>/dev/null; then
            log_info "Adding Walph entries to .gitignore..."
            echo "" >> "$target_dir/.gitignore"
            echo "# Walph Riggum" >> "$target_dir/.gitignore"
            echo ".walph/logs/" >> "$target_dir/.gitignore"
            echo ".walph/state/" >> "$target_dir/.gitignore"
        fi
    fi

    log_success "Setup complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Review and edit AGENTS.md with your build/test commands"
    echo "  2. Create specs in specs/ (copy TEMPLATE.md)"
    echo "  3. Run: walph plan"
    echo "  4. Review IMPLEMENTATION_PLAN.md"
    echo "  5. Run: walph build"
}
