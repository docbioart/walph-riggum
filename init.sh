#!/usr/bin/env bash
# Walph Riggum - Project Initialization
# Creates a new Walph-enabled project

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/project_setup.sh"
source "$SCRIPT_DIR/lib/docker.sh"

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

PROJECT_NAME=""
STACK=""
WITH_DOCKER=false
INIT_GIT=true

show_usage() {
    cat << 'EOF'
Walph Riggum - Project Initialization

USAGE:
    init.sh <project-name> [options]

OPTIONS:
    --stack <type>     Project stack: node, python, or both
    --docker           Include Docker configuration
    --no-git           Don't initialize git repository
    -h, --help         Show this help

EXAMPLES:
    ./init.sh my-app --stack node
    ./init.sh api-service --stack python --docker
    ./init.sh fullstack --stack both --docker
EOF
}

parse_args() {
    # Handle --help before anything else
    for arg in "$@"; do
        if [[ "$arg" == "-h" ]] || [[ "$arg" == "--help" ]]; then
            show_usage
            exit 0
        fi
    done

    if [[ $# -lt 1 ]]; then
        show_usage
        exit 1
    fi

    PROJECT_NAME="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stack)
                if [[ $# -lt 2 ]]; then
                    log_error "--stack requires a type argument"
                    show_usage
                    exit 1
                fi
                STACK="$2"
                shift 2
                ;;
            --docker)
                WITH_DOCKER=true
                shift
                ;;
            --no-git)
                INIT_GIT=false
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# ============================================================================
# PROJECT CREATION
# ============================================================================

create_walph_structure() {
    local project_dir="$1"

    log_info "Creating Walph directory structure..."

    mkdir -p "$project_dir/.walph/logs"
    mkdir -p "$project_dir/.walph/state"
    mkdir -p "$project_dir/specs"

    # Copy config template
    write_default_config "$project_dir/.walph/config"

    # Copy prompt templates
    if [[ -f "$SCRIPT_DIR/templates/PROMPT_plan.md" ]]; then
        cp "$SCRIPT_DIR/templates/PROMPT_plan.md" "$project_dir/.walph/"
    fi
    if [[ -f "$SCRIPT_DIR/templates/PROMPT_build.md" ]]; then
        cp "$SCRIPT_DIR/templates/PROMPT_build.md" "$project_dir/.walph/"
    fi
}

# Removed: now using create_agents_md from lib/project_setup.sh

create_implementation_plan() {
    local project_dir="$1"

    log_info "Creating empty IMPLEMENTATION_PLAN.md..."

    cat > "$project_dir/IMPLEMENTATION_PLAN.md" << 'EOF'
# Implementation Plan

<!-- This file will be populated by running 'walph plan' -->

## Overview

<!-- High-level description of what needs to be built -->

## Tasks

<!-- Tasks will be listed here in checkbox format:
- [ ] Task 1: Description
- [ ] Task 2: Description
- [x] Completed task
-->

## Architecture Decisions

<!-- Key architectural decisions and their rationale -->

## Dependencies

<!-- External dependencies and their versions -->
EOF
}

create_example_spec() {
    local project_dir="$1"

    log_info "Creating spec templates..."

    # Create README for specs directory
    cat > "$project_dir/specs/README.md" << 'EOF'
# Specifications

Put your feature specs in this directory. Walph reads ALL `.md` files here.

## How to Write a Spec

1. Copy `TEMPLATE.md` to `your-feature.md`
2. Fill in the sections
3. Be specific and include examples
4. List files that should be created

## What Makes a Good Spec

✅ **Good:**
- "POST /users creates a user and returns the user object with an id"
- "Division by zero returns 'Error: Division by zero'"
- "Files to create: src/auth.js, src/auth.test.js"

❌ **Bad:**
- "Handle user management"
- "Should work correctly"
- "Create the necessary files"

## Template Sections

| Section | Purpose |
|---------|---------|
| Overview | What and why (1-2 sentences) |
| Requirements | Specific, testable requirements |
| Technical Details | Files, APIs, data structures |
| Acceptance Criteria | Checkboxes Walph can verify |
| Examples | Input/output pairs |
EOF

    # Create spec template
    cat > "$project_dir/specs/TEMPLATE.md" << 'EOF'
# Feature: [Feature Name]

## Overview

[1-2 sentences: What are we building and why?]

## Requirements

### Must Have

1. [Specific, testable requirement]
2. [Specific, testable requirement]
3. [Specific, testable requirement]

## Technical Details

### Files to Create

- `[filename.js]` - [Purpose]
- `[filename.test.js]` - [What it tests]

### Interface/API (if applicable)

```
[Describe function signatures, CLI usage, or API endpoints]
```

## Acceptance Criteria

- [ ] [Testable criterion]
- [ ] [Testable criterion]
- [ ] All tests pass

## Examples

### Example 1: [Name]

**Input:**
```
[input]
```

**Output:**
```
[expected output]
```

### Example 2: [Edge Case]

**Input:**
```
[edge case input]
```

**Output:**
```
[expected output or error]
```
EOF
}

# Note: This function is now defined in lib/docker.sh
# init.sh calls it with postgres always enabled (the 4th parameter defaults to "true")

create_gitignore() {
    local project_dir="$1"

    log_info "Creating .gitignore..."
    cp "$SCRIPT_DIR/templates/gitignore.template" "$project_dir/.gitignore"
}

init_git() {
    local project_dir="$1"

    if [[ -d "$project_dir/.git" ]]; then
        log_info "Git repository already exists"
        return
    fi

    log_info "Initializing git repository..."

    (
        cd "$project_dir"
        git init
        git add .
        git commit -m "Initial commit with Walph Riggum setup"
    )
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    parse_args "$@"

    local project_dir
    if [[ "$PROJECT_NAME" == "." ]]; then
        project_dir="$(pwd)"
        PROJECT_NAME="$(basename "$project_dir")"
    else
        project_dir="$(pwd)/$PROJECT_NAME"
    fi

    log_info "Initializing Walph Riggum project: $PROJECT_NAME"

    # Create project directory if it doesn't exist
    if [[ ! -d "$project_dir" ]]; then
        mkdir -p "$project_dir"
    fi

    # Create Walph structure
    create_walph_structure "$project_dir"

    # Create AGENTS.md
    create_agents_md "$project_dir" "$STACK"

    # Create implementation plan template
    create_implementation_plan "$project_dir"

    # Create example spec
    create_example_spec "$project_dir"

    # Create Docker setup if requested
    if [[ "$WITH_DOCKER" == "true" ]]; then
        create_docker_setup "$project_dir" "$STACK" "$PROJECT_NAME" "true"
    fi

    # Create .gitignore
    create_gitignore "$project_dir"

    # Initialize git
    if [[ "$INIT_GIT" == "true" ]]; then
        init_git "$project_dir"
    fi

    log_success "Project initialized successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. cd $PROJECT_NAME"
    echo "  2. Edit specs/example.md with your requirements"
    echo "  3. Run: ../walph.sh plan"
    echo "  4. Review IMPLEMENTATION_PLAN.md"
    echo "  5. Run: ../walph.sh build"
}

main "$@"
