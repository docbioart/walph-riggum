#!/usr/bin/env bash
# Walph Riggum - Logging Utilities

# ============================================================================
# COLORS AND FORMATTING
# ============================================================================

# Check if terminal supports colors. The `tput colors` probe (and the || true
# guards) matter: with TERM=dumb/unknown, tput fails, and since this runs at
# source time under the caller's set -e, an unguarded failure would kill the
# tool before main() with no output at all.
if [[ -t 1 ]] && command -v tput &>/dev/null && tput colors &>/dev/null; then
    RED=$(tput setaf 1 || true)
    GREEN=$(tput setaf 2 || true)
    YELLOW=$(tput setaf 3 || true)
    BLUE=$(tput setaf 4 || true)
    MAGENTA=$(tput setaf 5 || true)
    CYAN=$(tput setaf 6 || true)
    BOLD=$(tput bold || true)
    RESET=$(tput sgr0 || true)
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
WALPH_LOG_FILE=""
WALPH_VERBOSE=false

init_logging() {
    local log_dir="$1"
    local session_id="$2"

    mkdir -p "$log_dir"
    WALPH_LOG_FILE="$log_dir/${LOG_FILE_PREFIX:-walph}_${session_id}.log"

    # Write session header
    {
        echo "============================================================"
        echo "${TOOL_NAME:-Walph Riggum} Session: $session_id"
        echo "Started: $(date -Iseconds)"
        echo "============================================================"
    } >> "$WALPH_LOG_FILE"
}

# Internal logging function
_log() {
    local level="$1"
    local color="$2"
    local message="$3"
    local timestamp
    timestamp=$(date '+%H:%M:%S')

    # Console output
    echo -e "${color}[${LOG_PREFIX:-WALPH}]${RESET} ${BOLD}[$level]${RESET} $message"

    # File output (without colors)
    if [[ -n "$WALPH_LOG_FILE" ]]; then
        echo "[$timestamp] [$level] $message" >> "$WALPH_LOG_FILE"
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
    if [[ "$WALPH_VERBOSE" == "true" ]]; then
        _log "DEBUG" "$MAGENTA" "$1"
    elif [[ -n "$WALPH_LOG_FILE" ]]; then
        # Always write debug to file
        local timestamp
        timestamp=$(date '+%H:%M:%S')
        echo "[$timestamp] [DEBUG] $1" >> "$WALPH_LOG_FILE"
    fi
}

# Log iteration start with fancy banner
log_iteration_start() {
    local iteration="$1"
    local max_iterations="$2"
    local mode="$3"

    # Calculate dynamic padding for proper alignment
    local text="Iteration $iteration / $max_iterations ($mode mode)"
    local box_width=60
    local text_length=${#text}
    local padding=$((box_width - text_length - 2))  # -2 for "║ " prefix

    echo ""
    echo "${CYAN}╔════════════════════════════════════════════════════════════╗${RESET}"
    printf "${CYAN}║${RESET} ${BOLD}Iteration %s / %s${RESET} (${MAGENTA}%s${RESET} mode)%*s${CYAN}║${RESET}\n" "$iteration" "$max_iterations" "$mode" "$padding" ""
    echo "${CYAN}╚════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    if [[ -n "$WALPH_LOG_FILE" ]]; then
        echo "" >> "$WALPH_LOG_FILE"
        echo "=== Iteration $iteration / $max_iterations ($mode mode) ===" >> "$WALPH_LOG_FILE"
    fi
}

# Append one line per iteration to a session summary CSV (cost, tokens,
# duration, outcome). Expensive iterations are a strong signal of
# under-specified specs. Cost is blank when the harness doesn't report dollars
# (codex); tokens are blank when unknown; usage_complete is false when the
# harness's event stream ended early (killed, crashed).
#
# Usage: log_iteration_summary <iteration> <mode> <model> <duration> <cost> <status> \
#                              [harness] [tokens_in] [tokens_out] [usage_complete]
log_iteration_summary() {
    local iteration="$1"
    local mode="$2"
    local model="$3"
    local duration="$4"
    local cost="$5"
    local status="$6"
    local harness="${7:-claude}"
    local tokens_in="${8:-}"
    local tokens_out="${9:-}"
    local usage_complete="${10:-}"

    [[ -z "$WALPH_LOG_FILE" ]] && return 0

    local summary_file="${WALPH_LOG_FILE%.log}_summary.csv"
    if [[ ! -f "$summary_file" ]]; then
        echo "timestamp,iteration,mode,harness,model,duration_seconds,cost_usd,tokens_in,tokens_out,usage_complete,status" > "$summary_file"
    fi
    # Status text may contain commas/quotes/newlines — flatten and wrap
    local safe_status="${status//$'\n'/ | }"
    safe_status="${safe_status//\"/\'}"
    echo "$(date -Iseconds),$iteration,$mode,$harness,${model:-default},$duration,${cost:-},${tokens_in:-},${tokens_out:-},${usage_complete:-},\"$safe_status\"" >> "$summary_file"
}

# Log the raw agent transcript (stdout stream and stderr) to the session log
# file only — the console shows the final response, not the event stream
log_harness_transcript() {
    local stdout_file="$1"
    local stderr_file="${2:-}"
    [[ -z "$WALPH_LOG_FILE" ]] && return 0

    if [[ -s "$stdout_file" ]]; then
        echo "--- harness stdout ---" >> "$WALPH_LOG_FILE"
        cat "$stdout_file" >> "$WALPH_LOG_FILE"
        echo "" >> "$WALPH_LOG_FILE"
    fi
    if [[ -n "$stderr_file" ]] && [[ -s "$stderr_file" ]]; then
        echo "--- harness stderr ---" >> "$WALPH_LOG_FILE"
        cat "$stderr_file" >> "$WALPH_LOG_FILE"
        echo "" >> "$WALPH_LOG_FILE"
    fi
    return 0
}
