#!/usr/bin/env bash
# Walph Riggum - Configuration
# Default settings and configuration management

# ============================================================================
# DEFAULT VALUES
# ============================================================================

DEFAULT_MAX_ITERATIONS=50
DEFAULT_MODEL_PLAN="opus"
DEFAULT_MODEL_BUILD="sonnet"
DEFAULT_LOG_DIR=".walph/logs"
DEFAULT_STATE_DIR=".walph/state"

# Circuit breaker thresholds
CIRCUIT_BREAKER_NO_CHANGE_THRESHOLD=3
CIRCUIT_BREAKER_SAME_ERROR_THRESHOLD=5
CIRCUIT_BREAKER_NO_COMMIT_THRESHOLD=5

# Rate limit handling
RATE_LIMIT_RETRY_DELAY=60  # seconds

# Iteration timeout (kill Claude if it hangs longer than this)
DEFAULT_ITERATION_TIMEOUT=900  # 15 minutes

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================

# Load configuration from multiple sources (later sources override earlier)
# Priority: defaults < config file < environment variables < command line
load_config() {
    local project_config="${PROJECT_DIR:-.}/.walph/config"

    # Load from config file if it exists (safely parse as key=value)
    if [[ -f "$project_config" ]]; then
        # Read config file line by line, validate format, and set variables
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Skip empty lines and comments
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

            # Validate line matches KEY=VALUE pattern (only uppercase letters, numbers, underscores in key)
            if [[ "$line" =~ ^[A-Z_][A-Z0-9_]*=(.*)$ ]]; then
                # Extract key and value
                local key="${line%%=*}"
                local value="${line#*=}"

                # Only allow known configuration variables
                case "$key" in
                    MAX_ITERATIONS|MODEL_PLAN|MODEL_BUILD|LOG_DIR|STATE_DIR|ITERATION_TIMEOUT|\
                    CIRCUIT_BREAKER_NO_CHANGE_THRESHOLD|CIRCUIT_BREAKER_SAME_ERROR_THRESHOLD|\
                    CIRCUIT_BREAKER_NO_COMMIT_THRESHOLD|RATE_LIMIT_RETRY_DELAY)
                        # Safe assignment using eval with proper quoting
                        eval "$key=\"\$value\""
                        ;;
                esac
            fi
        done < "$project_config"
    fi

    # Apply environment variable overrides
    MAX_ITERATIONS="${WALPH_MAX_ITERATIONS:-${MAX_ITERATIONS:-$DEFAULT_MAX_ITERATIONS}}"
    MODEL_PLAN="${WALPH_MODEL_PLAN:-${MODEL_PLAN:-$DEFAULT_MODEL_PLAN}}"
    MODEL_BUILD="${WALPH_MODEL_BUILD:-${MODEL_BUILD:-$DEFAULT_MODEL_BUILD}}"
    LOG_DIR="${WALPH_LOG_DIR:-${LOG_DIR:-$DEFAULT_LOG_DIR}}"
    STATE_DIR="${WALPH_STATE_DIR:-${STATE_DIR:-$DEFAULT_STATE_DIR}}"
    ITERATION_TIMEOUT="${WALPH_ITERATION_TIMEOUT:-${ITERATION_TIMEOUT:-$DEFAULT_ITERATION_TIMEOUT}}"
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

# Write default config file
write_default_config() {
    local config_file="$1"
    cat > "$config_file" << 'EOF'
# Walph Riggum Configuration
# Uncomment and modify as needed

# Maximum iterations before stopping
# MAX_ITERATIONS=50

# Models for each mode
# MODEL_PLAN="claude-opus-4-5-20250514"
# MODEL_BUILD="claude-sonnet-4-20250514"

# Logging directory (relative to project root)
# LOG_DIR=".walph/logs"

# Circuit breaker thresholds
# CIRCUIT_BREAKER_NO_CHANGE_THRESHOLD=3
# CIRCUIT_BREAKER_SAME_ERROR_THRESHOLD=5
# CIRCUIT_BREAKER_NO_COMMIT_THRESHOLD=5

# Iteration timeout in seconds (kills Claude if it hangs)
# ITERATION_TIMEOUT=900  # 15 minutes
EOF
}
