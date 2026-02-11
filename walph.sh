#!/usr/bin/env bash
# Walph Riggum - Autonomous Coding Loop
# Main orchestrator script

set -euo pipefail

# ============================================================================
# SCRIPT SETUP
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(pwd)"

# Source library files
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/circuit_breaker.sh"
source "$SCRIPT_DIR/lib/status_parser.sh"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/runner.sh"
source "$SCRIPT_DIR/lib/project_setup.sh"
source "$SCRIPT_DIR/lib/setup_command.sh"
source "$SCRIPT_DIR/lib/docker.sh"
source "$SCRIPT_DIR/lib/walph_help.sh"

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

MODE="build"
MAX_ITERATIONS=""
MODEL_OVERRIDE=""
MONITOR_MODE=false
DRY_RUN=false
VERBOSE=false

# Init command variables
INIT_PROJECT_NAME=""
INIT_TEMPLATE=""
INIT_STACK=""
INIT_DOCKER=false
INIT_POSTGRES=false

# Setup command variables
SETUP_STACK=""
SETUP_FORCE=false

parse_args() {
    # No arguments - show comprehensive how-to
    if [[ $# -eq 0 ]]; then
        show_howto
        exit 0
    fi

    # Handle init command specially (it has its own arguments)
    if [[ "${1:-}" == "init" ]]; then
        shift
        parse_init_args "$@"
        run_init
        exit 0
    fi

    # Handle setup command specially (it has its own arguments)
    if [[ "${1:-}" == "setup" ]]; then
        shift
        parse_setup_args "$@"
        run_setup
        exit 0
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            plan)
                MODE="plan"
                shift
                ;;
            build)
                MODE="build"
                shift
                ;;
            status)
                show_status
                exit 0
                ;;
            reset)
                reset_state
                exit 0
                ;;
            --max-iterations)
                if [[ $# -lt 2 ]]; then
                    log_error "--max-iterations requires a numeric argument"
                    show_help
                    exit 1
                fi
                if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    log_error "--max-iterations must be a positive integer"
                    show_help
                    exit 1
                fi
                MAX_ITERATIONS="$2"
                shift 2
                ;;
            --model)
                if [[ $# -lt 2 ]]; then
                    log_error "--model requires a model name argument"
                    show_help
                    exit 1
                fi
                MODEL_OVERRIDE="$2"
                shift 2
                ;;
            --monitor)
                MONITOR_MODE=true
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
            -h|--help)
                show_help
                exit 0
                ;;
            --version)
                show_version
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

parse_init_args() {
    # Check for help first
    for arg in "$@"; do
        if [[ "$arg" == "-h" ]] || [[ "$arg" == "--help" ]]; then
            show_init_help
            exit 0
        fi
        if [[ "$arg" == "--list-templates" ]]; then
            show_templates
            exit 0
        fi
    done

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --template|-t)
                INIT_TEMPLATE="$2"
                shift 2
                ;;
            --stack)
                INIT_STACK="$2"
                shift 2
                ;;
            --docker)
                INIT_DOCKER=true
                shift
                ;;
            --postgres)
                INIT_POSTGRES=true
                shift
                ;;
            -*)
                log_error "Unknown init option: $1"
                show_init_help
                exit 1
                ;;
            *)
                # First non-option argument is the project name
                if [[ -z "$INIT_PROJECT_NAME" ]]; then
                    INIT_PROJECT_NAME="$1"
                fi
                shift
                ;;
        esac
    done

    # Default to current directory if no name given
    if [[ -z "$INIT_PROJECT_NAME" ]]; then
        INIT_PROJECT_NAME="."
    fi

    # Apply template defaults
    apply_template_defaults
}

show_init_help() {
    cat << 'EOF'
Walph Riggum - Initialize Project

USAGE:
    walph.sh init [project-name] [options]

ARGUMENTS:
    project-name          Name of project directory (default: current directory)

TEMPLATES (--template, -t):
    api                   REST API service
    fullstack             Web app + Postgres + Docker
    cli                   Command-line tool
    ios                   Native iOS app (Swift/SwiftUI)
    android               Native Android app (Kotlin)
    capacitor             Web app + iOS/Android via Capacitor
    monorepo              Monorepo with multiple packages

OPTIONS:
    -t, --template <name> Architecture template (see above)
    --stack <type>        Language: node, python, swift, kotlin
    --docker              Include Docker configuration
    --postgres            Include PostgreSQL setup
    --list-templates      Show detailed template descriptions
    -h, --help            Show this help

EXAMPLES:
    walph.sh init my-api --template api --stack node
    walph.sh init my-app --template fullstack
    walph.sh init my-ios-app --template ios
    walph.sh init my-mobile --template capacitor
    walph.sh init my-tool --template cli --stack python

WHAT IT CREATES:
    .walph/                 # Walph configuration
    specs/                  # Your requirements go here
      └── TEMPLATE.md       # Copy this for each feature
    AGENTS.md               # Build/test/lint commands
    IMPLEMENTATION_PLAN.md  # Task list (generated by 'walph plan')
EOF
}

show_templates() {
    cat << 'EOF'
Walph Riggum - Architecture Templates

TEMPLATE: api
  Description: REST API service with tests
  Default stack: node
  Includes: Express/FastAPI, Jest/pytest, OpenAPI spec template
  Structure:
    src/
    ├── routes/
    ├── services/
    └── index.js
    tests/

TEMPLATE: fullstack
  Description: Full-stack web application
  Default stack: node
  Includes: Docker, Postgres, API + basic frontend
  Structure:
    src/
    ├── api/
    ├── web/
    └── db/
    docker-compose.yml

TEMPLATE: cli
  Description: Command-line tool
  Default stack: node
  Includes: Argument parsing, help generation
  Structure:
    src/
    ├── commands/
    └── cli.js

TEMPLATE: ios
  Description: Native iOS application
  Default stack: swift
  Includes: SwiftUI, XCTest, standard iOS structure
  Structure:
    MyApp/
    ├── Views/
    ├── Models/
    ├── Services/
    └── MyApp.swift
    MyAppTests/

TEMPLATE: android
  Description: Native Android application
  Default stack: kotlin
  Includes: Jetpack Compose, standard Android structure
  Structure:
    app/src/main/
    ├── java/.../
    │   ├── ui/
    │   └── data/
    └── res/

TEMPLATE: capacitor
  Description: Cross-platform app (Web + iOS + Android)
  Default stack: node
  Includes: Capacitor, web app, iOS/Android projects
  Structure:
    src/                  # Web app source
    ios/                  # iOS native project
    android/              # Android native project
    capacitor.config.ts

TEMPLATE: monorepo
  Description: Multi-package repository
  Default stack: node
  Includes: Workspace config, shared packages
  Structure:
    packages/
    ├── api/
    ├── web/
    └── shared/
    package.json (workspaces)

Use: walph.sh init my-app --template <name>
EOF
}

apply_template_defaults() {
    case "$INIT_TEMPLATE" in
        api)
            INIT_STACK="${INIT_STACK:-node}"
            ;;
        fullstack)
            INIT_STACK="${INIT_STACK:-node}"
            INIT_DOCKER=true
            INIT_POSTGRES=true
            ;;
        cli)
            INIT_STACK="${INIT_STACK:-node}"
            ;;
        ios)
            INIT_STACK="swift"
            ;;
        android)
            INIT_STACK="kotlin"
            ;;
        capacitor)
            INIT_STACK="${INIT_STACK:-node}"
            ;;
        monorepo)
            INIT_STACK="${INIT_STACK:-node}"
            ;;
    esac
}


# ============================================================================
# SETUP COMMAND (for existing projects)
# ============================================================================

# Setup command functions now in lib/setup_command.sh


# Generate Docker files based on template and stack
# Wrapper for the shared create_docker_setup function
create_docker_files() {
    local target_dir="$1"
    create_docker_setup "$target_dir" "$INIT_STACK" "$INIT_PROJECT_NAME" "$INIT_POSTGRES"
}

# ============================================================================
# STATUS AND RESET COMMANDS
# ============================================================================

show_status() {
    echo "Walph Riggum Status"
    echo "==================="
    echo ""
    echo "Project: $PROJECT_DIR"

    if [[ -d "$PROJECT_DIR/.walph" ]]; then
        echo "Walph initialized: Yes"

        # Circuit breaker status
        if [[ -f "$PROJECT_DIR/.walph/state/circuit_breaker.json" ]]; then
            init_circuit_breaker "$PROJECT_DIR/.walph/state"
            echo "Circuit breaker: $(get_circuit_breaker_status)"
        fi

        # Check for implementation plan
        if [[ -f "$PROJECT_DIR/IMPLEMENTATION_PLAN.md" ]]; then
            echo "Implementation plan: Found"
            # Count tasks (lines starting with - [ ])
            local total_tasks
            total_tasks=$(grep -c '^\s*- \[ \]' "$PROJECT_DIR/IMPLEMENTATION_PLAN.md" 2>/dev/null || echo "0")
            local completed_tasks
            completed_tasks=$(grep -c '^\s*- \[x\]' "$PROJECT_DIR/IMPLEMENTATION_PLAN.md" 2>/dev/null || echo "0")
            echo "Tasks: $completed_tasks completed, $total_tasks remaining"
        else
            echo "Implementation plan: Not found (run 'walph plan' first)"
        fi
    else
        echo "Walph initialized: No (run 'walph init' in project directory)"
    fi
}

reset_state() {
    log_info "Resetting Walph state..."

    if [[ -d "$PROJECT_DIR/.walph/state" ]]; then
        rm -f "$PROJECT_DIR/.walph/state/"*.json
        log_success "State reset complete"
    else
        log_warn "No state directory found"
    fi
}

# ============================================================================
# INIT COMMAND
# ============================================================================

run_init() {
    local target_dir

    if [[ "$INIT_PROJECT_NAME" == "." ]]; then
        target_dir="$(pwd)"
        INIT_PROJECT_NAME="$(basename "$target_dir")"
    else
        target_dir="$(pwd)/$INIT_PROJECT_NAME"
    fi

    log_info "Initializing Walph project: $INIT_PROJECT_NAME"

    # Create project directory if needed
    if [[ ! -d "$target_dir" ]]; then
        mkdir -p "$target_dir"
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

    # Create specs directory with templates
    log_info "Creating specs directory..."
    mkdir -p "$target_dir/specs"

    # Specs README
    cat > "$target_dir/specs/README.md" << 'EOF'
# Specifications

Put your feature specs in this directory. Walph reads ALL `.md` files here (except README.md).

## Quick Start

1. Copy `TEMPLATE.md` to `your-feature.md`
2. Fill in the sections
3. Run `walph plan` to generate tasks
4. Run `walph build` to implement

## What Makes a Good Spec

✅ **Good:**
- "POST /users creates a user and returns JSON with id"
- "Division by zero returns 'Error: Division by zero'"
- "Files to create: src/auth.js, src/auth.test.js"

❌ **Bad:**
- "Handle user management"
- "Should work correctly"
- "Create the necessary files"

## Key Sections

| Section | Purpose |
|---------|---------|
| Overview | What and why (1-2 sentences) |
| Requirements | Specific, testable items |
| Files to Create | What Walph should make |
| Acceptance Criteria | Checkboxes to verify |
| Examples | Input/output pairs |
EOF

    # Spec template
    cat > "$target_dir/specs/TEMPLATE.md" << 'EOF'
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

### Interface/API

```
[Function signatures, CLI usage, or API endpoints]
```

## Acceptance Criteria

- [ ] [Criterion 1]
- [ ] [Criterion 2]
- [ ] All tests pass

## Examples

### Example 1: [Happy Path]

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
[edge case]
```

**Output:**
```
[expected output or error]
```
EOF

    # Create AGENTS.md based on template and stack
    log_info "Creating AGENTS.md..."
    # Call shared function from lib/project_setup.sh with detailed mode (includes template)
    create_agents_md "$target_dir" "$INIT_STACK" "$INIT_TEMPLATE" "$INIT_PROJECT_NAME" "$INIT_DOCKER" "$INIT_POSTGRES"

    # Create empty IMPLEMENTATION_PLAN.md
    log_info "Creating IMPLEMENTATION_PLAN.md..."
    cat > "$target_dir/IMPLEMENTATION_PLAN.md" << 'EOF'
# Implementation Plan

> This file is generated by `walph plan`. Write your specs in `specs/` first.

## Overview

<!-- Will be filled by walph plan -->

## Tasks

<!-- Tasks will appear here as checkboxes:
- [ ] Task 1: Description
- [ ] Task 2: Description
- [x] Completed task
-->

Run `walph plan` to generate tasks from your specs.
EOF

    # Create .gitignore
    log_info "Creating .gitignore..."
    cp "$SCRIPT_DIR/templates/gitignore.template" "$target_dir/.gitignore"

    # Create Docker files if requested
    if [[ "$INIT_DOCKER" == "true" ]]; then
        log_info "Creating Docker configuration..."
        create_docker_files "$target_dir"
    fi

    # Initialize git if not already a repo
    if [[ ! -d "$target_dir/.git" ]]; then
        log_info "Initializing git repository..."
        (cd "$target_dir" && git init && git add . && git commit -m "Initialize Walph Riggum project") 2>/dev/null || true
    fi

    log_success "Project initialized!"
    echo ""
    echo "Next steps:"
    echo "  1. cd $INIT_PROJECT_NAME"
    echo "  2. Copy specs/TEMPLATE.md → specs/your-feature.md"
    echo "  3. Fill in your requirements"
    echo "  4. Run: walph plan"
    echo "  5. Review IMPLEMENTATION_PLAN.md"
    echo "  6. Run: walph build"
}

# ============================================================================
# MAIN LOOP
# ============================================================================

run_iteration() {
    local iteration="$1"
    local prompt_file="$2"
    local model="$3"

    # Walph has no additional template substitutions beyond the common ones
    # Call the shared iteration runner
    run_shared_iteration "$iteration" "$prompt_file" "$model" "$STATE_DIR"
}

main_loop() {
    # Use shared main loop implementation from lib/runner.sh
    run_main_loop ".walph" ".walph/state" "get_model_for_mode" "walph"
}

# ============================================================================
# INITIALIZATION AND MAIN
# ============================================================================

init_walph() {
    # Load configuration
    load_config

    # Apply command line overrides
    if [[ -n "$MAX_ITERATIONS" ]]; then
        MAX_ITERATIONS="$MAX_ITERATIONS"
    else
        MAX_ITERATIONS="${DEFAULT_MAX_ITERATIONS}"
    fi

    # Check dependencies
    if ! check_dependencies; then
        exit 1
    fi

    # Ensure directories exist
    ensure_directories "$PROJECT_DIR"

    # Initialize logging
    session_id=$(generate_session_id)
    init_logging "$PROJECT_DIR/$LOG_DIR" "$session_id"

    # Initialize circuit breaker
    init_circuit_breaker "$PROJECT_DIR/$STATE_DIR"

    # Export mode for circuit breaker
    export WALPH_MODE="$MODE"
    export TOOL_MODE="$MODE"

    # Set resume command for rate limit handler
    export RESUME_COMMAND="walph $MODE"

    log_info "Walph Riggum starting"
    log_info "Mode: $MODE"
    log_info "Max iterations: $MAX_ITERATIONS"
    log_debug "Project directory: $PROJECT_DIR"
    log_debug "Script directory: $SCRIPT_DIR"
}

main() {
    parse_args "$@"

    # Check if we're in a Walph-enabled project
    if [[ ! -d "$PROJECT_DIR/.walph" ]] && [[ ! -f "$PROJECT_DIR/AGENTS.md" ]]; then
        log_warn "This doesn't appear to be a Walph-enabled project."
        log_info "Run 'walph init' or create a .walph directory first."
        if ! ask_yes_no "Continue anyway?"; then
            exit 0
        fi
        mkdir -p "$PROJECT_DIR/.walph"
    fi

    init_walph

    # Start monitoring if requested
    if [[ "$MONITOR_MODE" == "true" ]]; then
        log_info "Starting monitoring session..."
        start_monitor_session "$PROJECT_DIR/$LOG_DIR/walph_${session_id}.log" "$PROJECT_DIR"
    fi

    # Run main loop
    main_loop
    local exit_code=$?

    # Summary
    echo ""
    log_info "Session complete"
    show_status

    exit $exit_code
}

# Run main
main "$@"
