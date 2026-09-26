#!/usr/bin/env bash
# Walph Riggum - Configuration
# Default settings and configuration management

# ============================================================================
# DEFAULT VALUES
# ============================================================================

DEFAULT_MAX_ITERATIONS=50
DEFAULT_LOG_DIR=".walph/logs"
DEFAULT_STATE_DIR=".walph/state"

# Model defaults are per harness — see harness_model_default in lib/harness.sh
# (claude: opus/sonnet/opus, codex: gpt-6-astra/gpt-5.6-sol/gpt-6-astra,
# opencode: the harness's own configured default)

# Circuit breaker thresholds
CIRCUIT_BREAKER_NO_CHANGE_THRESHOLD=3
CIRCUIT_BREAKER_SAME_ERROR_THRESHOLD=5
CIRCUIT_BREAKER_NO_COMMIT_THRESHOLD=5

# Rate limit handling
RATE_LIMIT_RETRY_DELAY=60  # seconds

# Iteration timeout (kill the agent if it hangs longer than this)
DEFAULT_ITERATION_TIMEOUT=900  # 15 minutes

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================

# Read KEY=VALUE lines from a config file into shell variables, accepting only
# the keys listed in <allowed_pattern> (an extended-regex alternation).
# Surrounding quotes on values are stripped so MODEL_PLAN="opus" means opus.
# Never sources the file: a committed config must not be able to run code.
load_config_file() {
    local config_file="$1"
    local allowed_pattern="$2"

    [[ -f "$config_file" ]] || return 0

    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Validate line matches KEY=VALUE (uppercase letters, digits, underscores in key)
        if [[ "$line" =~ ^[A-Z_][A-Z0-9_]*=(.*)$ ]]; then
            key="${line%%=*}"
            value="${line#*=}"
            value=$(harness_strip_quotes "$value")
            if [[ "$key" =~ ^(${allowed_pattern})$ ]]; then
                eval "$key=\"\$value\""
            fi
        fi
    done < "$config_file"
    return 0
}

WALPH_CONFIG_KEYS='MAX_ITERATIONS|MODEL_PLAN|MODEL_BUILD|MODEL_VERIFY|LOG_DIR|STATE_DIR|ITERATION_TIMEOUT|CIRCUIT_BREAKER_NO_CHANGE_THRESHOLD|CIRCUIT_BREAKER_SAME_ERROR_THRESHOLD|CIRCUIT_BREAKER_NO_COMMIT_THRESHOLD|RATE_LIMIT_RETRY_DELAY|HARNESS|REASONING_EFFORT|PLAN_REVIEWER'

# Load configuration from multiple sources (later sources override earlier)
# Priority: defaults < config file < environment variables < command line
#
# Expects (optionally) from the caller: HARNESS_OVERRIDE (--harness),
# MODEL_OVERRIDE (--model), MODE (used to validate --model against the harness).
load_config() {
    local project_config="${PROJECT_DIR:-.}/.walph/config"

    load_config_file "$project_config" "$WALPH_CONFIG_KEYS"

    # The harness comes first: model defaults depend on it
    resolve_harness "${HARNESS_OVERRIDE:-}" "${WALPH_HARNESS:-}" "${HARNESS:-}" || return 1

    MAX_ITERATIONS="${WALPH_MAX_ITERATIONS:-${MAX_ITERATIONS:-$DEFAULT_MAX_ITERATIONS}}"
    LOG_DIR="${WALPH_LOG_DIR:-${LOG_DIR:-$DEFAULT_LOG_DIR}}"
    STATE_DIR="${WALPH_STATE_DIR:-${STATE_DIR:-$DEFAULT_STATE_DIR}}"
    ITERATION_TIMEOUT="${WALPH_ITERATION_TIMEOUT:-${ITERATION_TIMEOUT:-$DEFAULT_ITERATION_TIMEOUT}}"
    REASONING_EFFORT="${WALPH_REASONING_EFFORT:-${REASONING_EFFORT:-}}"
    PLAN_REVIEWER="${WALPH_PLAN_REVIEWER:-${PLAN_REVIEWER:-}}"

    harness_resolve_model MODEL_PLAN   plan   "${WALPH_MODEL_PLAN:-}"   || return 1
    harness_resolve_model MODEL_BUILD  build  "${WALPH_MODEL_BUILD:-}"  || return 1
    harness_resolve_model MODEL_VERIFY verify "${WALPH_MODEL_VERIFY:-}" || return 1

    # --model applies to every phase of this run; reject a Claude-only name on
    # another harness up front instead of failing on the first iteration
    if [[ -n "${MODEL_OVERRIDE:-}" ]]; then
        # shellcheck disable=SC2034  # written through eval by harness_resolve_model
        local checked_override="$MODEL_OVERRIDE"
        harness_resolve_model checked_override "${MODE:-build}" "" "$MODEL_OVERRIDE" || return 1
    fi
    return 0
}

# Get the model for a given mode
get_model_for_mode() {
    local mode="$1"
    case "$mode" in
        plan)
            echo "$MODEL_PLAN"
            ;;
        build)
            echo "$MODEL_BUILD"
            ;;
        verify)
            echo "$MODEL_VERIFY"
            ;;
        *)
            echo "$MODEL_BUILD"
            ;;
    esac
}

# Ensure required directories exist
ensure_directories() {
    local project_dir="${1:-.}"
    mkdir -p "$project_dir/$LOG_DIR"
    mkdir -p "$project_dir/$STATE_DIR"
}

# Write default config file (shared by init, setup, and legacy init.sh)
write_default_config() {
    local config_file="$1"
    cat > "$config_file" << 'CONFIG'
# Walph Riggum Configuration
# Uncomment and modify as needed. Values may be quoted or bare.

# Agent CLI that runs each iteration: claude (default), codex, or opencode.
# Also settable with --harness or WALPH_HARNESS.
# HARNESS=claude

# Maximum iterations before stopping
# MAX_ITERATIONS=50

# Models per phase. Defaults depend on the harness:
#   claude:   plan=opus         build=sonnet       verify=opus
#   codex:    plan=gpt-6-astra  build=gpt-5.6-sol  verify=gpt-6-astra
#   opencode: whatever your opencode.json "model" says (use provider/model here)
# MODEL_PLAN="opus"
# MODEL_BUILD="sonnet"
# MODEL_VERIFY="opus"

# Reasoning effort for harnesses that support it (codex: low..max, opencode: --variant)
# REASONING_EFFORT=high

# Second-model plan review after `walph plan` (harness or harness:model). No default.
# PLAN_REVIEWER=codex:gpt-6-astra

# Iteration timeout in seconds (kills the agent if it hangs)
# ITERATION_TIMEOUT=900

# Circuit breaker thresholds
# CIRCUIT_BREAKER_NO_CHANGE_THRESHOLD=3
# CIRCUIT_BREAKER_SAME_ERROR_THRESHOLD=5
# CIRCUIT_BREAKER_NO_COMMIT_THRESHOLD=5

# Logging directory (relative to project root)
# LOG_DIR=".walph/logs"
CONFIG
}
