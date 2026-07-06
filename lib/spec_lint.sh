#!/usr/bin/env bash
# Walph Riggum - Spec Lint
# Structural checks on spec files, and ground-truth checkbox helpers.
# Used by walph (plan gate, completion gate), jeeroy (post-generation check),
# and goodbunny (fix-mode completion gate).

# Files in specs/ that are not feature specs and should be skipped
_is_non_spec_file() {
    local name
    name=$(basename "$1")
    case "$name" in
        README.md|TEMPLATE.md|decisions.md) return 0 ;;
        *) return 1 ;;
    esac
}

# Lint a single spec file for required/recommended sections.
# Prints one warning line per issue to stdout.
# Returns 0 if clean, 1 if issues found.
lint_spec_file() {
    local file="$1"
    local name
    name=$(basename "$file")
    local issues=0

    if ! grep -qE '^##+ .*Requirements' "$file"; then
        echo "specs/$name: missing '## Requirements' section"
        issues=1
    fi
    if ! grep -qE '^##+ .*Acceptance Criteria' "$file"; then
        echo "specs/$name: missing '## Acceptance Criteria' section"
        issues=1
    elif ! grep -qE '^[[:space:]]*- \[[ x]\]' "$file"; then
        echo "specs/$name: 'Acceptance Criteria' has no checkbox items (- [ ] ...)"
        issues=1
    fi
    if ! grep -qE '^##+ .*Examples' "$file"; then
        echo "specs/$name: missing '## Examples' section (input/output examples make specs much more buildable)"
        issues=1
    fi

    return $issues
}

# Lint all spec files in a directory.
# Logs warnings for each issue. Returns the number of files with issues (0 = clean).
# Also returns non-zero (via count) if the directory has no spec files at all.
lint_specs() {
    local specs_dir="$1"
    local files_with_issues=0
    local spec_count=0

    if [[ ! -d "$specs_dir" ]]; then
        log_warn "Specs directory not found: $specs_dir"
        return 1
    fi

    for file in "$specs_dir"/*.md; do
        [[ -f "$file" ]] || continue
        _is_non_spec_file "$file" && continue
        spec_count=$((spec_count + 1))

        local issues
        if ! issues=$(lint_spec_file "$file"); then
            files_with_issues=$((files_with_issues + 1))
            while IFS= read -r line; do
                [[ -n "$line" ]] && log_warn "$line"
            done <<< "$issues"
        fi
    done

    if [[ $spec_count -eq 0 ]]; then
        log_warn "No spec files found in $specs_dir (README.md/TEMPLATE.md don't count)"
        return 1
    fi

    if [[ $files_with_issues -gt 0 ]]; then
        log_warn "$files_with_issues of $spec_count spec file(s) have structural issues — vague specs produce vague code"
    else
        log_debug "Spec lint: $spec_count spec file(s) look structurally sound"
    fi

    return $files_with_issues
}

# Check whether a file (or every spec .md in a directory) still contains
# unchecked checkboxes (- [ ]). Used as a ground-truth gate so a hallucinated
# EXIT_SIGNAL from Claude can't end the loop while work remains on disk.
# Returns 0 if unchecked boxes exist, 1 if none.
has_unchecked_boxes() {
    local target="$1"

    if [[ -f "$target" ]]; then
        grep -qE '^[[:space:]]*- \[ \]' "$target"
        return $?
    fi

    if [[ -d "$target" ]]; then
        for file in "$target"/*.md; do
            [[ -f "$file" ]] || continue
            _is_non_spec_file "$file" && continue
            if grep -qE '^[[:space:]]*- \[ \]' "$file"; then
                return 0
            fi
        done
    fi

    return 1
}
