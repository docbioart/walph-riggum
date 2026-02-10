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
                MAX_ITERATIONS="$2"
                shift 2
                ;;
            --model)
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

create_setup_agents_md() {
    local target_dir="$1"
    local stack="$2"
    local project_name
    project_name=$(basename "$target_dir")

    local build_cmd test_cmd lint_cmd

    case "$stack" in
        node)
            build_cmd="npm run build"
            test_cmd="npm test"
            lint_cmd="npm run lint"
            ;;
        python)
            build_cmd="pip install -e ."
            test_cmd="pytest"
            lint_cmd="ruff check ."
            ;;
        swift)
            build_cmd="swift build"
            test_cmd="swift test"
            lint_cmd="swiftlint"
            ;;
        kotlin)
            build_cmd="./gradlew assembleDebug"
            test_cmd="./gradlew test"
            lint_cmd="./gradlew ktlintCheck"
            ;;
        go)
            build_cmd="go build ./..."
            test_cmd="go test ./..."
            lint_cmd="golangci-lint run"
            ;;
        rust)
            build_cmd="cargo build"
            test_cmd="cargo test"
            lint_cmd="cargo clippy"
            ;;
        *)
            build_cmd="# Add your build command"
            test_cmd="# Add your test command"
            lint_cmd="# Add your lint command"
            ;;
    esac

    cat > "$target_dir/AGENTS.md" << EOF
# Project: $project_name

## Stack: $stack

## Build Commands

\`\`\`bash
$build_cmd
\`\`\`

## Test Commands

\`\`\`bash
$test_cmd
\`\`\`

## Lint Commands

\`\`\`bash
$lint_cmd
\`\`\`

## Notes for Claude

- Follow existing code patterns and style
- Run tests after making changes
- Commit after each completed task
- Check existing files before creating new ones

<!-- Add project-specific notes below -->
EOF
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
        create_setup_agents_md "$target_dir" "$stack"
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

# Generate AGENTS.md based on template and stack
create_agents_md() {
    local target_dir="$1"
    local build_cmd test_cmd lint_cmd structure notes

    # Set defaults based on stack
    case "$INIT_STACK" in
        node)
            build_cmd="npm run build"
            test_cmd="npm test"
            lint_cmd="npm run lint"
            ;;
        python)
            build_cmd="pip install -e ."
            test_cmd="pytest"
            lint_cmd="ruff check ."
            ;;
        swift)
            build_cmd="xcodebuild -scheme $INIT_PROJECT_NAME -destination 'platform=iOS Simulator,name=iPhone 15' build"
            test_cmd="xcodebuild -scheme $INIT_PROJECT_NAME -destination 'platform=iOS Simulator,name=iPhone 15' test"
            lint_cmd="swiftlint"
            ;;
        kotlin)
            build_cmd="./gradlew assembleDebug"
            test_cmd="./gradlew test"
            lint_cmd="./gradlew ktlintCheck"
            ;;
        *)
            build_cmd="# Add your build command"
            test_cmd="# Add your test command"
            lint_cmd="# Add your lint command"
            ;;
    esac

    # Override/extend based on template
    case "$INIT_TEMPLATE" in
        api)
            if [[ "$INIT_STACK" == "node" ]]; then
                structure="$INIT_PROJECT_NAME/
├── src/
│   ├── routes/        # API route handlers
│   ├── services/      # Business logic
│   ├── middleware/    # Express middleware
│   └── index.js       # Entry point
├── tests/
├── package.json
└── specs/"
                notes="- Use Express.js for the API framework
- Follow RESTful conventions
- Validate all inputs
- Return appropriate HTTP status codes
- Write integration tests for endpoints"
            else
                structure="$INIT_PROJECT_NAME/
├── src/
│   ├── routes/        # API route handlers
│   ├── services/      # Business logic
│   └── main.py        # Entry point
├── tests/
├── requirements.txt
└── specs/"
                notes="- Use FastAPI for the API framework
- Follow RESTful conventions
- Use Pydantic for validation
- Return appropriate HTTP status codes"
            fi
            ;;

        fullstack)
            structure="$INIT_PROJECT_NAME/
├── src/
│   ├── api/           # Backend API
│   ├── web/           # Frontend
│   └── db/            # Database migrations
├── docker/
├── docker-compose.yml
├── package.json
└── specs/"
            notes="- API in src/api/, frontend in src/web/
- Use environment variables for config
- Database migrations in src/db/
- docker-compose up for local development"
            ;;

        cli)
            if [[ "$INIT_STACK" == "node" ]]; then
                structure="$INIT_PROJECT_NAME/
├── src/
│   ├── commands/      # Command implementations
│   ├── utils/         # Helper functions
│   └── cli.js         # Entry point
├── bin/               # Executable scripts
├── tests/
├── package.json
└── specs/"
                notes="- Use commander.js or yargs for argument parsing
- Support --help and --version flags
- Exit with appropriate codes (0=success, 1=error)
- Write tests for each command"
            else
                structure="$INIT_PROJECT_NAME/
├── src/
│   ├── commands/      # Command implementations
│   ├── utils/         # Helper functions
│   └── cli.py         # Entry point
├── tests/
├── setup.py
└── specs/"
                notes="- Use click or argparse for argument parsing
- Support --help and --version flags
- Exit with appropriate codes
- Make it installable via pip"
            fi
            ;;

        ios)
            build_cmd="xcodebuild -project $INIT_PROJECT_NAME.xcodeproj -scheme $INIT_PROJECT_NAME -destination 'platform=iOS Simulator,name=iPhone 15' build"
            test_cmd="xcodebuild -project $INIT_PROJECT_NAME.xcodeproj -scheme $INIT_PROJECT_NAME -destination 'platform=iOS Simulator,name=iPhone 15' test"
            structure="$INIT_PROJECT_NAME/
├── $INIT_PROJECT_NAME/
│   ├── App/           # App entry point
│   ├── Views/         # SwiftUI views
│   ├── Models/        # Data models
│   ├── ViewModels/    # View models
│   ├── Services/      # API/data services
│   └── Resources/     # Assets, strings
├── ${INIT_PROJECT_NAME}Tests/
├── $INIT_PROJECT_NAME.xcodeproj
└── specs/"
            notes="- Use SwiftUI for UI
- Follow MVVM architecture
- Use Combine for reactive programming
- Support iOS 16+
- Use Swift Package Manager for dependencies
- Write XCTest unit tests"
            ;;

        android)
            structure="$INIT_PROJECT_NAME/
├── app/
│   ├── src/main/
│   │   ├── java/com/example/$INIT_PROJECT_NAME/
│   │   │   ├── ui/           # Compose UI
│   │   │   ├── data/         # Repositories, data sources
│   │   │   ├── domain/       # Use cases, models
│   │   │   └── MainActivity.kt
│   │   └── res/              # Resources
│   └── build.gradle.kts
├── build.gradle.kts
└── specs/"
            notes="- Use Jetpack Compose for UI
- Follow MVVM architecture
- Use Kotlin Coroutines for async
- Support Android API 26+
- Use Hilt for dependency injection
- Write JUnit tests"
            ;;

        capacitor)
            build_cmd="npm run build && npx cap sync"
            test_cmd="npm test"
            structure="$INIT_PROJECT_NAME/
├── src/               # Web app source (React/Vue/etc)
│   ├── components/
│   ├── pages/
│   └── services/
├── ios/               # iOS native project
├── android/           # Android native project
├── capacitor.config.ts
├── package.json
└── specs/"
            notes="- Web app in src/, built with Vite/webpack
- Run 'npx cap sync' after web build
- iOS: open ios/App/App.xcworkspace in Xcode
- Android: open android/ in Android Studio
- Use Capacitor plugins for native features
- Test web version first, then native"
            ;;

        monorepo)
            build_cmd="npm run build --workspaces"
            test_cmd="npm test --workspaces"
            lint_cmd="npm run lint --workspaces"
            structure="$INIT_PROJECT_NAME/
├── packages/
│   ├── api/           # Backend service
│   ├── web/           # Frontend app
│   └── shared/        # Shared utilities/types
├── package.json       # Workspace root
└── specs/"
            notes="- Use npm/yarn/pnpm workspaces
- Shared code in packages/shared
- Each package has its own package.json
- Import shared code: @$INIT_PROJECT_NAME/shared"
            ;;

        *)
            # Default structure
            structure="$INIT_PROJECT_NAME/
├── src/               # Source code
├── tests/             # Test files
└── specs/             # Requirements"
            notes="- Follow existing code patterns
- Write tests for new functionality"
            ;;
    esac

    # Add postgres note if enabled
    if [[ "$INIT_POSTGRES" == "true" ]]; then
        notes="$notes
- PostgreSQL connection via DATABASE_URL env var
- Run migrations before starting app"
    fi

    # Add docker note if enabled
    if [[ "$INIT_DOCKER" == "true" ]]; then
        notes="$notes
- Use 'docker-compose up' for local development
- All services defined in docker-compose.yml"
    fi

    cat > "$target_dir/AGENTS.md" << EOF
# Project: $INIT_PROJECT_NAME

## Template: ${INIT_TEMPLATE:-custom}
## Stack: ${INIT_STACK:-not specified}

## Build Commands

\`\`\`bash
$build_cmd
\`\`\`

## Test Commands

\`\`\`bash
$test_cmd
\`\`\`

## Lint Commands

\`\`\`bash
$lint_cmd
\`\`\`

## Project Structure

\`\`\`
$structure
\`\`\`

## Notes for Claude

- Always run tests after making changes
- Commit after each completed task
- Follow existing code style and patterns
$notes
EOF
}

# Generate Docker files based on template and stack
create_docker_files() {
    local target_dir="$1"
    mkdir -p "$target_dir/docker"

    local app_port="3000"
    local db_section=""

    if [[ "$INIT_STACK" == "python" ]]; then
        app_port="8000"
    fi

    # Add Postgres if requested
    if [[ "$INIT_POSTGRES" == "true" ]]; then
        db_section="
  db:
    image: postgres:15-alpine
    environment:
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=postgres
      - POSTGRES_DB=$INIT_PROJECT_NAME
    ports:
      - \"5432:5432\"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: [\"CMD-SHELL\", \"pg_isready -U postgres\"]
      interval: 5s
      timeout: 5s
      retries: 5

volumes:
  postgres_data:"
    fi

    # Docker compose
    cat > "$target_dir/docker-compose.yml" << EOF
version: '3.8'

services:
  app:
    build:
      context: .
      dockerfile: docker/Dockerfile
    ports:
      - "$app_port:$app_port"
    volumes:
      - .:/app
      - /app/node_modules
    environment:
      - NODE_ENV=development${INIT_POSTGRES:+
      - DATABASE_URL=postgres://postgres:postgres@db:5432/$INIT_PROJECT_NAME}
${INIT_POSTGRES:+    depends_on:
      db:
        condition: service_healthy}
    restart: unless-stopped
$db_section
EOF

    # Dockerfile based on stack
    case "$INIT_STACK" in
        python)
            cat > "$target_dir/docker/Dockerfile" << 'EOF'
FROM python:3.11-slim

WORKDIR /app

# Install dependencies
COPY requirements*.txt ./
RUN pip install --no-cache-dir -r requirements.txt 2>/dev/null || echo "No requirements.txt"

# Copy source
COPY . .

EXPOSE 8000

CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
EOF
            ;;
        *)
            cat > "$target_dir/docker/Dockerfile" << 'EOF'
FROM node:20-alpine

WORKDIR /app

# Install dependencies
COPY package*.json ./
RUN npm ci 2>/dev/null || npm init -y

# Copy source
COPY . .

EXPOSE 3000

CMD ["npm", "run", "dev"]
EOF
            ;;
    esac
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
    create_agents_md "$target_dir"

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
    cat > "$target_dir/.gitignore" << 'EOF'
# Dependencies
node_modules/
venv/
__pycache__/
*.pyc

# Build
dist/
build/
*.egg-info/

# IDE
.idea/
.vscode/
*.swp

# Environment
.env
.env.local

# Logs
*.log

# Ralph (keep config and prompts, ignore state and logs)
.walph/logs/
.walph/state/

# OS
.DS_Store
EOF

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

    log_iteration_start "$iteration" "$MAX_ITERATIONS" "$MODE"

    # Build the prompt
    local full_prompt=""

    # Add prompt template
    if [[ -f "$prompt_file" ]]; then
        full_prompt=$(cat "$prompt_file")
    else
        log_error "Prompt file not found: $prompt_file"
        return 1
    fi

    # Substitute variables in prompt
    full_prompt=$(echo "$full_prompt" | sed "s/{{ITERATION}}/$iteration/g")
    full_prompt=$(echo "$full_prompt" | sed "s/{{MAX_ITERATIONS}}/$MAX_ITERATIONS/g")
    full_prompt=$(echo "$full_prompt" | sed "s/{{MODE}}/$MODE/g")

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run Claude with:"
        echo "  Model: $model"
        echo "  Prompt file: $prompt_file"
        echo "  Mode: $MODE"
        return 0
    fi

    # Run Claude
    log_info "Running Claude ($model)..."

    local output
    local exit_code=0

    # Create temp file for output
    local temp_output
    temp_output=$(mktemp)

    # Run Claude with streaming, capture output
    if echo "$full_prompt" | claude -p \
        --dangerously-skip-permissions \
        --model "$model" \
        2>&1 | tee "$temp_output"; then
        exit_code=0
    else
        exit_code=$?
    fi

    output=$(cat "$temp_output")
    rm -f "$temp_output"

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
        return 0
    fi

    return "$exit_code"
}

main_loop() {
    local iteration=1

    while [[ $iteration -le $MAX_ITERATIONS ]]; do
        # Check circuit breaker before iteration
        if circuit_breaker_triggered; then
            log_error "Circuit breaker triggered - stopping loop"
            log_info "Run 'walph reset' to clear the circuit breaker"
            return 1
        fi

        # Select prompt and model
        local prompt_file
        if [[ -f "$PROJECT_DIR/.walph/PROMPT_${MODE}.md" ]]; then
            prompt_file="$PROJECT_DIR/.walph/PROMPT_${MODE}.md"
        elif [[ -f "$SCRIPT_DIR/templates/PROMPT_${MODE}.md" ]]; then
            prompt_file="$SCRIPT_DIR/templates/PROMPT_${MODE}.md"
        else
            log_error "No prompt template found for mode: $MODE"
            return 1
        fi

        local model
        if [[ -n "$MODEL_OVERRIDE" ]]; then
            model="$MODEL_OVERRIDE"
        else
            model=$(get_model_for_mode "$MODE")
        fi

        # Run iteration (export for rate limit context)
        WALPH_CURRENT_ITERATION="$iteration"
        local result
        if run_iteration "$iteration" "$prompt_file" "$model"; then
            # Check if we got completion signal
            log_success "Iteration $iteration completed successfully"
        else
            result=$?
            if [[ $result -eq 2 ]]; then
                log_info "Exit requested by user"
                return 0
            fi
            log_warn "Iteration $iteration completed with issues"
        fi

        # Check again for completion (from status parser)
        if [[ -f "$PROJECT_DIR/.walph/state/completion_signal" ]]; then
            log_success "All tasks completed!"
            rm -f "$PROJECT_DIR/.walph/state/completion_signal"
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
    local session_id
    session_id=$(generate_session_id)
    init_logging "$PROJECT_DIR/$LOG_DIR" "$session_id"

    # Initialize circuit breaker
    init_circuit_breaker "$PROJECT_DIR/$STATE_DIR"

    # Export mode for circuit breaker
    export WALPH_MODE="$MODE"

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
        start_monitor_session "$PROJECT_DIR/$LOG_DIR/walph_$(generate_session_id).log" "$PROJECT_DIR"
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
