#!/usr/bin/env bash

# Shared project setup functions for Walph and init.sh
# This consolidates AGENTS.md generation logic

# Get the script directory (templates are relative to this)
_get_template_dir() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    echo "$script_dir/../templates/agents"
}

# Load template file and substitute variables
# Usage: _load_template <template_file> <project_name>
_load_template() {
    local template_file="$1"
    local project_name="$2"

    if [[ ! -f "$template_file" ]]; then
        return 1
    fi

    # Read and substitute {{PROJECT_NAME}}
    sed "s/{{PROJECT_NAME}}/$project_name/g" "$template_file"
}

# Generate AGENTS.md with support for basic and detailed modes
# Usage: create_agents_md <target_dir> <stack> [template] [project_name] [docker] [postgres]
create_agents_md() {
    local target_dir="$1"
    local stack="$2"
    local template="${3:-}"
    local project_name="${4:-$(basename "$target_dir")}"
    local docker="${5:-false}"
    local postgres="${6:-false}"

    local template_dir
    template_dir="$(_get_template_dir)"

    local build_cmd test_cmd lint_cmd structure notes

    # Load stack-specific commands from template file
    local stack_file="$template_dir/stacks/${stack}.txt"
    if [[ -f "$stack_file" ]]; then
        # Read stack file and extract commands
        build_cmd=$(grep "^build_cmd=" "$stack_file" | cut -d= -f2-)
        test_cmd=$(grep "^test_cmd=" "$stack_file" | cut -d= -f2-)
        lint_cmd=$(grep "^lint_cmd=" "$stack_file" | cut -d= -f2-)
    else
        # Unknown stack - use defaults
        build_cmd="# Add your build command"
        test_cmd="# Add your test command"
        lint_cmd="# Add your lint command"
    fi

    # Load template-specific structure and notes
    if [[ -n "$template" ]]; then
        local template_file=""

        # Determine which template file to use
        case "$template" in
            api)
                if [[ "$stack" == "node" ]]; then
                    template_file="$template_dir/templates/api-node.txt"
                else
                    template_file="$template_dir/templates/api-python.txt"
                fi
                ;;
            cli)
                if [[ "$stack" == "node" ]]; then
                    template_file="$template_dir/templates/cli-node.txt"
                else
                    template_file="$template_dir/templates/cli-python.txt"
                fi
                ;;
            fullstack|ios|android|capacitor|monorepo)
                template_file="$template_dir/templates/${template}.txt"
                ;;
            *)
                # Default structure for unknown templates
                structure="$project_name/
├── src/               # Source code
├── tests/             # Test files
└── specs/             # Requirements"
                notes="- Follow existing code patterns
- Write tests for new functionality"
                ;;
        esac

        # Load and parse template file if it exists
        if [[ -n "$template_file" ]] && [[ -f "$template_file" ]]; then
            local template_content
            template_content=$(_load_template "$template_file" "$project_name")

            # Extract structure and notes from template content
            structure=$(echo "$template_content" | sed -n '/^structure=/,/^notes=/p' | sed '1s/^structure=//;$d')
            notes=$(echo "$template_content" | sed -n '/^notes=/,$p' | sed '1s/^notes=//')

            # Override build/test commands if specified in template
            local template_build_cmd template_test_cmd template_lint_cmd
            template_build_cmd=$(echo "$template_content" | grep "^build_cmd=" | cut -d= -f2-)
            template_test_cmd=$(echo "$template_content" | grep "^test_cmd=" | cut -d= -f2-)
            template_lint_cmd=$(echo "$template_content" | grep "^lint_cmd=" | cut -d= -f2-)

            [[ -n "$template_build_cmd" ]] && build_cmd="$template_build_cmd"
            [[ -n "$template_test_cmd" ]] && test_cmd="$template_test_cmd"
            [[ -n "$template_lint_cmd" ]] && lint_cmd="$template_lint_cmd"
        fi
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
