#!/usr/bin/env bash

# Shared project setup functions for Walph and init.sh
# This consolidates AGENTS.md generation logic

# Generate AGENTS.md with support for basic and detailed modes
# Usage: create_agents_md <target_dir> <stack> [template] [project_name] [docker] [postgres]
create_agents_md() {
    local target_dir="$1"
    local stack="$2"
    local template="${3:-}"
    local project_name="${4:-$(basename "$target_dir")}"
    local docker="${5:-false}"
    local postgres="${6:-false}"

    local build_cmd test_cmd lint_cmd structure notes

    # Set defaults based on stack
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
        both)
            # Legacy support for init.sh
            build_cmd="npm run build && pip install -e ."
            test_cmd="npm test && pytest"
            lint_cmd="npm run lint && ruff check ."
            ;;
        *)
            build_cmd="# Add your build command"
            test_cmd="# Add your test command"
            lint_cmd="# Add your lint command"
            ;;
    esac

    # Override/extend based on template (if provided)
    if [[ -n "$template" ]]; then
        case "$template" in
            api)
                if [[ "$stack" == "node" ]]; then
                    structure="$project_name/
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
                    structure="$project_name/
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
                structure="$project_name/
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
                if [[ "$stack" == "node" ]]; then
                    structure="$project_name/
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
                    structure="$project_name/
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
                build_cmd="xcodebuild -project $project_name.xcodeproj -scheme $project_name -destination 'platform=iOS Simulator,name=iPhone 15' build"
                test_cmd="xcodebuild -project $project_name.xcodeproj -scheme $project_name -destination 'platform=iOS Simulator,name=iPhone 15' test"
                structure="$project_name/
├── $project_name/
│   ├── App/           # App entry point
│   ├── Views/         # SwiftUI views
│   ├── Models/        # Data models
│   ├── ViewModels/    # View models
│   ├── Services/      # API/data services
│   └── Resources/     # Assets, strings
├── ${project_name}Tests/
├── $project_name.xcodeproj
└── specs/"
                notes="- Use SwiftUI for UI
- Follow MVVM architecture
- Use Combine for reactive programming
- Support iOS 16+
- Use Swift Package Manager for dependencies
- Write XCTest unit tests"
                ;;

            android)
                structure="$project_name/
├── app/
│   ├── src/main/
│   │   ├── java/com/example/$project_name/
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
                structure="$project_name/
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
                structure="$project_name/
├── packages/
│   ├── api/           # Backend service
│   ├── web/           # Frontend app
│   └── shared/        # Shared utilities/types
├── package.json       # Workspace root
└── specs/"
                notes="- Use npm/yarn/pnpm workspaces
- Shared code in packages/shared
- Each package has its own package.json
- Import shared code: @$project_name/shared"
                ;;

            *)
                # Default structure
                structure="$project_name/
├── src/               # Source code
├── tests/             # Test files
└── specs/             # Requirements"
                notes="- Follow existing code patterns
- Write tests for new functionality"
                ;;
        esac
    else
        # Basic mode - no template-specific structure
        structure="<!-- Describe your project structure here -->"
        notes="- Follow existing code style and patterns
- Ask for clarification if requirements are unclear"
    fi

    # Add postgres note if enabled
    if [[ "$postgres" == "true" ]]; then
        notes="$notes
- PostgreSQL connection via DATABASE_URL env var
- Run migrations before starting app"
    fi

    # Add docker note if enabled
    if [[ "$docker" == "true" ]]; then
        notes="$notes
- Use 'docker-compose up' for local development
- All services defined in docker-compose.yml"
    fi

    # Generate the AGENTS.md file
    cat > "$target_dir/AGENTS.md" << EOF
# Project: $project_name

EOF

    # Add template/stack info if in detailed mode
    if [[ -n "$template" ]]; then
        cat >> "$target_dir/AGENTS.md" << EOF
## Template: ${template}
## Stack: ${stack}

EOF
    else
        # Basic mode - just show build/test/lint
        :
    fi

    cat >> "$target_dir/AGENTS.md" << EOF
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

EOF

    # Add structure section
    if [[ -n "$template" ]]; then
        cat >> "$target_dir/AGENTS.md" << EOF
## Project Structure

\`\`\`
$structure
\`\`\`

EOF
    else
        # Basic mode includes empty structure section
        cat >> "$target_dir/AGENTS.md" << EOF
## Project Structure

$structure

## Key Files

<!-- List important files and their purposes -->

EOF
    fi

    cat >> "$target_dir/AGENTS.md" << EOF
## Notes for Claude

- Always run tests after making changes
- Commit after each completed task
EOF

    # Add additional notes
    if [[ -n "$notes" ]]; then
        echo "$notes" >> "$target_dir/AGENTS.md"
    fi
}
