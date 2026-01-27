#!/usr/bin/env bash
# Ralph Wiggum - Logging Utilities

# ============================================================================
# COLORS AND FORMATTING
# ============================================================================

# Check if terminal supports colors
if [[ -t 1 ]] && command -v tput &>/dev/null; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    MAGENTA=$(tput setaf 5)
    CYAN=$(tput setaf 6)
    BOLD=$(tput bold)
    RESET=$(tput sgr0)
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    MAGENTA=""
    CYAN=""
    BOLD=""
    RESET=""
fi

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

# Current log file (set by init_logging)
RALPH_LOG_FILE=""
RALPH_VERBOSE=false

init_logging() {
    local log_dir="$1"
    local session_id="$2"

    mkdir -p "$log_dir"
    RALPH_LOG_FILE="$log_dir/ralph_${session_id}.log"

    # Write session header
    {
        echo "============================================================"
        echo "Ralph Wiggum Session: $session_id"
        echo "Started: $(date -Iseconds)"
        echo "============================================================"
    } >> "$RALPH_LOG_FILE"
}

# Internal logging function
_log() {
    local level="$1"
    local color="$2"
    local message="$3"
    local timestamp
    timestamp=$(date '+%H:%M:%S')

    # Console output
    echo -e "${color}[RALPH]${RESET} ${BOLD}[$level]${RESET} $message"

    # File output (without colors)
    if [[ -n "$RALPH_LOG_FILE" ]]; then
        echo "[$timestamp] [$level] $message" >> "$RALPH_LOG_FILE"
    fi
}

log_info() {
    _log "INFO" "$BLUE" "$1"
}

log_success() {
    _log "OK" "$GREEN" "$1"
}

log_warn() {
    _log "WARN" "$YELLOW" "$1"
}

log_error() {
    _log "ERROR" "$RED" "$1"
}

log_debug() {
    if [[ "$RALPH_VERBOSE" == "true" ]]; then
        _log "DEBUG" "$MAGENTA" "$1"
    elif [[ -n "$RALPH_LOG_FILE" ]]; then
        # Always write debug to file
        local timestamp
        timestamp=$(date '+%H:%M:%S')
        echo "[$timestamp] [DEBUG] $1" >> "$RALPH_LOG_FILE"
    fi
}

# Log iteration start with fancy banner
log_iteration_start() {
    local iteration="$1"
    local max_iterations="$2"
    local mode="$3"

    echo ""
    echo "${CYAN}╔════════════════════════════════════════════════════════════╗${RESET}"
    echo "${CYAN}║${RESET} ${BOLD}Iteration $iteration / $max_iterations${RESET} (${MAGENTA}$mode${RESET} mode)                        ${CYAN}║${RESET}"
    echo "${CYAN}╚════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    if [[ -n "$RALPH_LOG_FILE" ]]; then
        echo "" >> "$RALPH_LOG_FILE"
        echo "=== Iteration $iteration / $max_iterations ($mode mode) ===" >> "$RALPH_LOG_FILE"
    fi
}

# Log raw Claude output to file
log_claude_output() {
    local output="$1"
    if [[ -n "$RALPH_LOG_FILE" ]]; then
        echo "$output" >> "$RALPH_LOG_FILE"
    fi
}
