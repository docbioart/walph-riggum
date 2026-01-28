#!/usr/bin/env bash
# Jeeroy Lenkins - Document Conversion Library
# Converts various document formats to markdown using pandoc

# ============================================================================
# SUPPORTED FORMATS
# ============================================================================

# Files that can be read directly (no conversion needed)
DIRECT_READ_EXTENSIONS=("md" "txt" "markdown")

# Files that require pandoc conversion
PANDOC_EXTENSIONS=("docx" "doc" "pptx" "ppt" "rtf" "html" "htm" "odt" "epub")

# PDF needs special handling (pandoc or pdftotext fallback)
PDF_EXTENSIONS=("pdf")

# ============================================================================
# DEPENDENCY CHECKS
# ============================================================================

check_pandoc() {
    if command -v pandoc &>/dev/null; then
        return 0
    fi

    log_error "pandoc is not installed."
    echo ""
    echo "Install pandoc:"
    case "$(uname -s)" in
        Darwin)
            echo "  brew install pandoc"
            ;;
        Linux)
            echo "  sudo apt-get install pandoc    # Debian/Ubuntu"
            echo "  sudo dnf install pandoc        # Fedora"
            echo "  sudo pacman -S pandoc           # Arch"
            ;;
        *)
            echo "  See: https://pandoc.org/installing.html"
            ;;
    esac
    return 1
}

check_pdftotext() {
    command -v pdftotext &>/dev/null
}

# ============================================================================
# FORMAT DETECTION
# ============================================================================

# Get the file extension (lowercase, portable across bash 3.2+)
get_extension() {
    local file="$1"
    local ext="${file##*.}"
    echo "$ext" | tr '[:upper:]' '[:lower:]'
}

# Check if a file extension is in an array
extension_in_list() {
    local ext="$1"
    shift
    local list=("$@")
    for item in "${list[@]}"; do
        if [[ "$ext" == "$item" ]]; then
            return 0
        fi
    done
    return 1
}

# Check if a file is a supported format
is_supported_file() {
    local file="$1"
    local ext
    ext=$(get_extension "$file")

    extension_in_list "$ext" "${DIRECT_READ_EXTENSIONS[@]}" && return 0
    extension_in_list "$ext" "${PANDOC_EXTENSIONS[@]}" && return 0
    extension_in_list "$ext" "${PDF_EXTENSIONS[@]}" && return 0
    return 1
}

# Get all supported extensions as a display string
get_supported_extensions_display() {
    local all=()
    all+=("${DIRECT_READ_EXTENSIONS[@]}")
    all+=("${PANDOC_EXTENSIONS[@]}")
    all+=("${PDF_EXTENSIONS[@]}")
    local IFS=", "
    echo "${all[*]}"
}

# Portable relative path (works on macOS and Linux)
_relative_path() {
    local target="$1"
    local base="$2"

    # Try realpath --relative-to first (Linux/GNU coreutils)
    if realpath --relative-to="$base" "$target" 2>/dev/null; then
        return 0
    fi

    # Try python3 fallback (macOS)
    if command -v python3 &>/dev/null; then
        python3 -c "import os; print(os.path.relpath('$target', '$base'))" 2>/dev/null && return 0
    fi

    # Last resort: just use the basename
    basename "$target"
}

# ============================================================================
# CONVERSION FUNCTIONS
# ============================================================================

# Convert a single file to markdown
# Returns the markdown content on stdout
# Returns 0 on success, 1 on failure
convert_file() {
    local file="$1"
    local ext
    ext=$(get_extension "$file")
    local filename
    filename=$(basename "$file")

    if [[ ! -f "$file" ]]; then
        log_error "File not found: $file" >&2
        return 1
    fi

    # Direct read formats
    if extension_in_list "$ext" "${DIRECT_READ_EXTENSIONS[@]}"; then
        cat "$file"
        return 0
    fi

    # PDF handling (pandoc first, pdftotext fallback)
    if extension_in_list "$ext" "${PDF_EXTENSIONS[@]}"; then
        if command -v pandoc &>/dev/null; then
            if pandoc -f pdf -t markdown --wrap=none "$file" 2>/dev/null; then
                return 0
            fi
            log_debug "pandoc failed for $filename, trying pdftotext..." >&2
        fi

        if check_pdftotext; then
            pdftotext -layout "$file" - 2>/dev/null
            return $?
        fi

        log_warn "Cannot convert PDF: $filename (install pandoc or pdftotext)" >&2
        printf '%s\n' "[PDF file: $filename - could not be converted]"
        return 1
    fi

    # Pandoc conversion for everything else
    if extension_in_list "$ext" "${PANDOC_EXTENSIONS[@]}"; then
        if ! command -v pandoc &>/dev/null; then
            log_warn "pandoc not installed, skipping: $filename" >&2
            printf '%s\n' "[File: $filename - requires pandoc to convert]"
            return 1
        fi

        # Attempt conversion
        if pandoc -t markdown --wrap=none "$file" 2>/dev/null; then
            return 0
        else
            log_warn "pandoc conversion failed for: $filename" >&2
            printf '%s\n' "[File: $filename - conversion failed]"
            return 1
        fi
    fi

    log_warn "Unsupported format: $filename" >&2
    return 1
}

# Convert all supported files in a directory
# Outputs combined markdown with source markers to stdout
# Logs summary to stderr
# Args: directory_path [recursive: true/false]
convert_directory() {
    local dir="$1"
    local recursive="${2:-false}"

    if [[ ! -d "$dir" ]]; then
        log_error "Directory not found: $dir" >&2
        return 1
    fi

    local file_count=0
    local success_count=0
    local fail_count=0

    # Build file list
    local files=()
    if [[ "$recursive" == "true" ]]; then
        while IFS= read -r -d '' file; do
            files+=("$file")
        done < <(find "$dir" -type f -print0 | sort -z)
    else
        while IFS= read -r -d '' file; do
            files+=("$file")
        done < <(find "$dir" -maxdepth 1 -type f -print0 | sort -z)
    fi

    for file in "${files[@]}"; do
        if ! is_supported_file "$file"; then
            continue
        fi

        file_count=$((file_count + 1))
        local filename
        filename=$(basename "$file")
        local relpath
        relpath=$(_relative_path "$file" "$dir")

        log_debug "Converting: $relpath" >&2

        local content
        if content=$(convert_file "$file"); then
            success_count=$((success_count + 1))
            # Output with source markers
            printf '\n'
            printf '%s\n' "=== SOURCE: $relpath ==="
            printf '\n'
            printf '%s\n' "$content"
            printf '\n'
            printf '%s\n' "=== END: $relpath ==="
            printf '\n'
        else
            fail_count=$((fail_count + 1))
            printf '\n'
            printf '%s\n' "=== SOURCE: $relpath ==="
            printf '\n'
            printf '%s\n' "[Conversion failed for this file]"
            printf '\n'
            printf '%s\n' "=== END: $relpath ==="
            printf '\n'
        fi
    done

    # Log summary to stderr (not stdout)
    if [[ $file_count -eq 0 ]]; then
        log_warn "No supported files found in: $dir" >&2
        log_info "Supported formats: $(get_supported_extensions_display)" >&2
        return 1
    fi

    log_info "Converted $success_count/$file_count files ($fail_count failed)" >&2
    return 0
}

# Get a summary of files in a directory by type
# Outputs to stdout (display function)
get_conversion_summary() {
    local dir="$1"

    local md_count=0
    local txt_count=0
    local docx_count=0
    local pdf_count=0
    local pptx_count=0
    local other_count=0
    local unsupported_count=0

    for file in "$dir"/*; do
        [[ -f "$file" ]] || continue
        local ext
        ext=$(get_extension "$file")

        if extension_in_list "$ext" "${DIRECT_READ_EXTENSIONS[@]}"; then
            case "$ext" in
                md|markdown) md_count=$((md_count + 1)) ;;
                txt) txt_count=$((txt_count + 1)) ;;
            esac
        elif extension_in_list "$ext" "${PANDOC_EXTENSIONS[@]}"; then
            case "$ext" in
                docx|doc) docx_count=$((docx_count + 1)) ;;
                pptx|ppt) pptx_count=$((pptx_count + 1)) ;;
                *) other_count=$((other_count + 1)) ;;
            esac
        elif extension_in_list "$ext" "${PDF_EXTENSIONS[@]}"; then
            pdf_count=$((pdf_count + 1))
        else
            unsupported_count=$((unsupported_count + 1))
        fi
    done

    echo "Files found:"
    if [[ $md_count -gt 0 ]]; then echo "  Markdown: $md_count"; fi
    if [[ $txt_count -gt 0 ]]; then echo "  Text: $txt_count"; fi
    if [[ $docx_count -gt 0 ]]; then echo "  Word: $docx_count"; fi
    if [[ $pdf_count -gt 0 ]]; then echo "  PDF: $pdf_count"; fi
    if [[ $pptx_count -gt 0 ]]; then echo "  PowerPoint: $pptx_count"; fi
    if [[ $other_count -gt 0 ]]; then echo "  Other supported: $other_count"; fi
    if [[ $unsupported_count -gt 0 ]]; then echo "  Unsupported (skipped): $unsupported_count"; fi
}
