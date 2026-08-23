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

# Image files (referenced for Claude vision in interactive mode)
IMAGE_EXTENSIONS=("jpg" "jpeg" "png" "gif" "webp" "svg")

# Code/config files (read directly, wrapped in code fences)
CODE_EXTENSIONS=("js" "jsx" "ts" "tsx" "py" "rb" "java" "kt" "swift" "go" "rs"
    "c" "cpp" "h" "hpp" "cs" "php" "sh" "bash" "zsh" "sql"
    "json" "yaml" "yml" "toml" "xml" "csv" "env" "ini" "cfg" "conf"
    "dockerfile" "makefile" "r" "scala" "lua" "pl" "ex" "exs" "vue" "svelte")

# Archive files (extracted and recursively processed)
ZIP_EXTENSIONS=("zip")

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

check_unzip() {
    if command -v unzip &>/dev/null; then
        return 0
    fi

    log_error "unzip is not installed."
    echo ""
    echo "Install unzip:"
    case "$(uname -s)" in
        Darwin)
            echo "  brew install unzip"
            ;;
        Linux)
            echo "  sudo apt-get install unzip    # Debian/Ubuntu"
            echo "  sudo dnf install unzip        # Fedora"
            echo "  sudo pacman -S unzip           # Arch"
            ;;
        *)
            echo "  Install unzip for your platform"
            ;;
    esac
    return 1
}

# ============================================================================
# ZIP TEMP-DIR CLEANUP
# ============================================================================

# Extraction dirs registered for cleanup at (sub)shell exit. rm -rf on an
# already-removed dir is harmless, so the happy path's explicit rm is fine.
_CONVERTER_ZIP_DIRS=()

_converter_cleanup_zip_dirs() {
    if [[ "${#_CONVERTER_ZIP_DIRS[@]}" -gt 0 ]]; then
        rm -rf -- "${_CONVERTER_ZIP_DIRS[@]}" 2>/dev/null || true
        _CONVERTER_ZIP_DIRS=()
    fi
}

# ============================================================================
# FORMAT DETECTION
# ============================================================================

# Get the file extension (lowercase, portable across bash 3.2+).
# Works on the basename: "${file##*.}" on a dotless filename would return the
# whole path (so /docs/Dockerfile could never match the dockerfile entry, and
# /Users/j.doe/README would yield "doe/readme").
get_extension() {
    local base
    base=$(basename "$1")
    local ext
    if [[ "$base" == *.* ]]; then
        ext="${base##*.}"
    else
        # No dot: use the whole name so extensionless entries in
        # CODE_EXTENSIONS (dockerfile, makefile) can match
        ext="$base"
    fi
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

# Map file extension to markdown code fence language name
ext_to_lang() {
    local ext="$1"
    case "$ext" in
        js|jsx)      echo "javascript" ;;
        ts|tsx)      echo "typescript" ;;
        py)          echo "python" ;;
        rb)          echo "ruby" ;;
        kt)          echo "kotlin" ;;
        rs)          echo "rust" ;;
        c|h)         echo "c" ;;
        cpp|hpp)     echo "cpp" ;;
        cs)          echo "csharp" ;;
        sh|bash|zsh) echo "bash" ;;
        yml)         echo "yaml" ;;
        ex|exs)      echo "elixir" ;;
        pl)          echo "perl" ;;
        dockerfile)  echo "dockerfile" ;;
        makefile)    echo "makefile" ;;
        *)           echo "$ext" ;;
    esac
}

# Check if a file is a supported format
is_supported_file() {
    local file="$1"
    local ext
    ext=$(get_extension "$file")

    extension_in_list "$ext" "${DIRECT_READ_EXTENSIONS[@]}" && return 0
    extension_in_list "$ext" "${PANDOC_EXTENSIONS[@]}" && return 0
    extension_in_list "$ext" "${PDF_EXTENSIONS[@]}" && return 0
    extension_in_list "$ext" "${IMAGE_EXTENSIONS[@]}" && return 0
    extension_in_list "$ext" "${CODE_EXTENSIONS[@]}" && return 0
    extension_in_list "$ext" "${ZIP_EXTENSIONS[@]}" && return 0
    return 1
}

# Get all supported extensions as a display string
get_supported_extensions_display() {
    local all=()
    all+=("${DIRECT_READ_EXTENSIONS[@]}")
    all+=("${PANDOC_EXTENSIONS[@]}")
    all+=("${PDF_EXTENSIONS[@]}")
    all+=("${IMAGE_EXTENSIONS[@]}")
    all+=("${CODE_EXTENSIONS[@]}")
    all+=("${ZIP_EXTENSIONS[@]}")
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

    # Pure bash fallback: strip base path prefix if target starts with base
    # This handles the common case of files within the base directory
    if [[ "$target" == "$base"/* ]]; then
        echo "${target#$base/}"
        return 0
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

    # PDF handling: pdftotext is the ONLY converter — pandoc can write PDFs
    # but has no PDF *reader*, so `pandoc -f pdf` fails on every file
    if extension_in_list "$ext" "${PDF_EXTENSIONS[@]}"; then
        if check_pdftotext; then
            pdftotext -layout "$file" - 2>/dev/null
            return $?
        fi

        log_warn "Cannot convert PDF: $filename (install pdftotext: brew install poppler)" >&2
        printf '%s\n' "[PDF file: $filename - could not be converted]"
        return 1
    fi

    # Image files: output a reference marker (Claude vision can read these in interactive mode)
    if extension_in_list "$ext" "${IMAGE_EXTENSIONS[@]}"; then
        local abs_path
        abs_path=$(cd "$(dirname "$file")" && pwd)/$(basename "$file")
        printf '[IMAGE FILE: %s]\n' "$filename"
        printf 'Location: %s\n' "$abs_path"
        printf 'This is an image file. If you have file access, examine it visually for\n'
        printf 'diagrams, wireframes, screenshots, or other visual requirements.\n'
        return 0
    fi

    # Code/config files: read directly, wrap in fenced code block
    if extension_in_list "$ext" "${CODE_EXTENSIONS[@]}"; then
        local lang
        lang=$(ext_to_lang "$ext")
        printf '```%s\n' "$lang"
        cat "$file"
        printf '\n```\n'
        return 0
    fi

    # ZIP archives: extract to temp dir, recursively process contents
    if extension_in_list "$ext" "${ZIP_EXTENSIONS[@]}"; then
        if ! check_unzip 2>/dev/null; then
            log_warn "unzip not installed, skipping: $filename" >&2
            printf '[Archive: %s - requires unzip to extract]\n' "$filename"
            return 1
        fi

        # Depth cap: a zip-inside-zip chain (or a zip quine) would otherwise
        # recurse without bound. Docs piles are untrusted input.
        local depth="${_CONVERTER_ZIP_DEPTH:-0}"
        if [[ "$depth" -ge 3 ]]; then
            log_warn "Nested archive too deep, skipping: $filename" >&2
            printf '[Archive: %s - nested too deeply, skipped]\n' "$filename"
            return 1
        fi

        local temp_dir
        temp_dir=$(mktemp -d)
        # This runs inside $(...) command substitution, so a trap in the
        # parent can't see our registration — clean up on subshell exit via
        # a global array (a trap referencing the local would hit set -u when
        # the local expires; each nesting level is its own subshell)
        _CONVERTER_ZIP_DIRS+=("$temp_dir")
        trap '_converter_cleanup_zip_dirs' EXIT

        if unzip -q -o "$file" -d "$temp_dir" 2>/dev/null; then
            # Drop symlinks: a malicious archive can use them to write or
            # read outside the extraction dir (zip-slip via symlink)
            find "$temp_dir" -type l -delete 2>/dev/null || true
            log_debug "Extracted $filename to temp dir" >&2
            _CONVERTER_ZIP_DEPTH=$((depth + 1)) convert_directory "$temp_dir" "true"
            local rc=$?
            rm -rf "$temp_dir"
            return $rc
        else
            log_warn "Failed to extract: $filename" >&2
            printf '[Archive: %s - extraction failed]\n' "$filename"
            rm -rf "$temp_dir"
            return 1
        fi
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
    local image_count=0
    local code_count=0
    local zip_count=0
    local other_count=0
    local unsupported_count=0

    # find (not a glob): must agree with convert_directory, which includes
    # dotfiles — a glob would undercount what actually gets converted
    local file
    while IFS= read -r -d '' file; do
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
        elif extension_in_list "$ext" "${IMAGE_EXTENSIONS[@]}"; then
            image_count=$((image_count + 1))
        elif extension_in_list "$ext" "${CODE_EXTENSIONS[@]}"; then
            code_count=$((code_count + 1))
        elif extension_in_list "$ext" "${ZIP_EXTENSIONS[@]}"; then
            zip_count=$((zip_count + 1))
        else
            unsupported_count=$((unsupported_count + 1))
        fi
    done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null)

    echo "Files found:"
    if [[ $md_count -gt 0 ]]; then echo "  Markdown: $md_count"; fi
    if [[ $txt_count -gt 0 ]]; then echo "  Text: $txt_count"; fi
    if [[ $docx_count -gt 0 ]]; then echo "  Word: $docx_count"; fi
    if [[ $pdf_count -gt 0 ]]; then echo "  PDF: $pdf_count"; fi
    if [[ $pptx_count -gt 0 ]]; then echo "  PowerPoint: $pptx_count"; fi
    if [[ $image_count -gt 0 ]]; then echo "  Images: $image_count"; fi
    if [[ $code_count -gt 0 ]]; then echo "  Code/Config: $code_count"; fi
    if [[ $zip_count -gt 0 ]]; then echo "  Archives (ZIP): $zip_count"; fi
    if [[ $other_count -gt 0 ]]; then echo "  Other supported: $other_count"; fi
    if [[ $unsupported_count -gt 0 ]]; then echo "  Unsupported (skipped): $unsupported_count"; fi
}
