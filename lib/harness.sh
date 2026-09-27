#!/usr/bin/env bash
# Walph Riggum - Harness abstraction
#
# The only file that knows how to invoke, restrict, and parse a specific
# agent CLI. Supported harnesses: claude (Claude Code), codex (OpenAI Codex
# CLI), opencode (OpenCode). Everything else in the repo goes through:
#
#   resolve_harness        pick the harness (flag > env > config > claude)
#   harness_check_installed
#   harness_model_default  per-harness default model for a phase
#   harness_exec           run one bounded, non-interactive invocation
#   harness_parse_result   turn the output files into HARNESS_* globals
#   harness_interactive_cmd  argv for an interactive session (Jeeroy Q&A)
#
# Written for bash 3.2 (macOS /bin/bash): no associative arrays, no
# namerefs, and every array expansion is guarded against `set -u`.
#
# shellcheck disable=SC2034  # HARNESS_* globals are read by lib/runner.sh and callers

# ============================================================================
# STATE
# ============================================================================

HARNESS="${HARNESS:-}"          # resolved harness name
HARNESS_PID=""                  # PID of the invocation currently running

# Argv/env of the last command built by harness_build_cmd
HARNESS_CMD=()
HARNESS_ENV=()

# Result of the last harness_parse_result (reset on every call)
HARNESS_TEXT=""                 # final assistant response (control channel)
HARNESS_TEXT_OK=false           # true when a usable final response was found
HARNESS_COST_USD=""             # "" = unknown (codex never reports dollars)
HARNESS_TOKENS_IN=""            # "" = unknown
HARNESS_TOKENS_OUT=""           # "" = unknown
HARNESS_USAGE_COMPLETE=false    # true when the stream ended normally
HARNESS_ERRORS=""               # structured error messages, one per line
HARNESS_MALFORMED_LINES=0       # JSONL lines that failed to parse

# ============================================================================
# RESOLUTION
# ============================================================================

harness_is_supported() {
    case "$1" in
        claude|codex|opencode) return 0 ;;
        *) return 1 ;;
    esac
}

# resolve_harness <cli_override> <env_value> <config_value>
# Sets and exports HARNESS. Returns 1 (after logging) on an unknown name.
resolve_harness() {
    local candidate="" source=""
    if [[ -n "${1:-}" ]]; then
        candidate="$1"; source="--harness"
    elif [[ -n "${2:-}" ]]; then
        candidate="$2"; source="environment"
    elif [[ -n "${3:-}" ]]; then
        candidate="$3"; source="config file"
    else
        candidate="claude"; source="default"
    fi

    if ! harness_is_supported "$candidate"; then
        log_error "Unknown harness '$candidate' (from $source). Supported: claude, codex, opencode"
        return 1
    fi

    HARNESS="$candidate"
    export HARNESS
    return 0
}

harness_display_name() {
    case "${1:-$HARNESS}" in
        claude)   echo "Claude Code" ;;
        codex)    echo "Codex CLI" ;;
        opencode) echo "OpenCode" ;;
        *)        echo "$1" ;;
    esac
}

harness_install_hint() {
    case "${1:-$HARNESS}" in
        claude)   echo "npm install -g @anthropic-ai/claude-code   (https://docs.claude.com/claude-code)" ;;
        codex)    echo "npm install -g @openai/codex  or  brew install codex" ;;
        opencode) echo "brew install opencode  or  npm install -g opencode-ai   (https://opencode.ai)" ;;
    esac
}

# harness_check_installed [name] — logs an error with an install hint if missing
harness_check_installed() {
    local name="${1:-$HARNESS}"
    if command -v "$name" &>/dev/null; then
        return 0
    fi
    log_error "$(harness_display_name "$name") CLI not found ('$name' is not on PATH)"
    echo "  Install: $(harness_install_hint "$name")"
    return 1
}

# ============================================================================
# MODELS
# ============================================================================

# harness_model_default <phase> [harness]
# Phases: plan build verify audit fix analyze review
# Empty output means "let the harness use its own configured default".
harness_model_default() {
    local phase="$1"
    local name="${2:-$HARNESS}"
    case "$name" in
        claude)
            case "$phase" in
                build|fix) echo "sonnet" ;;
                *)         echo "opus" ;;
            esac
            ;;
        codex)
            case "$phase" in
                build|fix) echo "gpt-5.6-sol" ;;
                *)         echo "gpt-6-astra" ;;
            esac
            ;;
        opencode)
            echo ""
            ;;
    esac
}

# A model name that only Claude Code understands (alias or full Claude id)
harness_is_claude_model() {
    case "$1" in
        opus|sonnet|haiku|claude-*|claude*) return 0 ;;
        *) return 1 ;;
    esac
}

# Strip one pair of matching surrounding quotes from a config value:
#   "opus" -> opus,  'opus' -> opus,  opus -> opus
harness_strip_quotes() {
    local value="$1"
    if [[ ${#value} -ge 2 ]]; then
        local first="${value:0:1}" last="${value: -1}"
        if [[ "$first" == "$last" ]] && [[ "$first" == '"' || "$first" == "'" ]]; then
            value="${value:1:${#value}-2}"
        fi
    fi
    printf '%s' "$value"
}

# harness_resolve_model <var_name> <phase> <env_value> <explicit_flag_value>
# Resolves the model for a phase into the named variable. Precedence:
# --model flag > env var > config value already in the variable > harness
# default. A Claude-only name inherited from config/defaults on a non-Claude
# harness is replaced by the harness default with a warning; one given
# explicitly via --model is an error.
harness_resolve_model() {
    local var_name="$1" phase="$2" env_value="${3:-}" flag_value="${4:-}"
    local config_value
    eval "config_value=\"\${$var_name:-}\""
    config_value=$(harness_strip_quotes "$config_value")

    local value source
    if [[ -n "$flag_value" ]]; then
        value="$flag_value"; source="--model"
    elif [[ -n "$env_value" ]]; then
        value=$(harness_strip_quotes "$env_value"); source="environment"
    elif [[ -n "$config_value" ]]; then
        value="$config_value"; source="config"
    else
        value=$(harness_model_default "$phase"); source="default"
    fi

    if [[ "$HARNESS" != "claude" ]] && [[ -n "$value" ]] && harness_is_claude_model "$value"; then
        if [[ "$source" == "--model" ]]; then
            log_error "Model '$value' is a Claude model but the harness is $HARNESS. Pass a $HARNESS model name with --model."
            return 1
        fi
        local fallback
        fallback=$(harness_model_default "$phase")
        log_warn "Model '$value' (from $source) is a Claude model; using the $HARNESS default for $phase: ${fallback:-<harness default>}"
        value="$fallback"
    fi

    eval "$var_name=\"\$value\""
    return 0
}

# ============================================================================
# COMMAND CONSTRUCTION
# ============================================================================

# Restricted OpenCode runs deny mutation tools. The deny rules are merged into
# any OPENCODE_CONFIG_CONTENT the user already exported (setting the variable
# would otherwise replace their inline config wholesale).
_harness_opencode_restricted_config() {
    local deny='{"permission":{"edit":"deny","bash":"deny","webfetch":"deny","task":"deny"}}'
    local existing="${OPENCODE_CONFIG_CONTENT:-}"
    if [[ -n "$existing" ]] && jq -e . >/dev/null 2>&1 <<< "$existing"; then
        jq -c --argjson deny "$deny" '. * $deny' <<< "$existing"
    else
        printf '%s' "$deny"
    fi
}

# harness_build_cmd <model> <access> [final_file]
#   access: full       - the agent may edit files and run commands unprompted
#           restricted - best-effort read-only (see README "Harnesses")
# Populates HARNESS_CMD (argv) and HARNESS_ENV (NAME=VALUE pairs).
harness_build_cmd() {
    local model="$1" access="$2" final_file="${3:-}"
    local effort="${REASONING_EFFORT:-}"
    local project_dir="${PROJECT_DIR:-$(pwd)}"
    HARNESS_CMD=()
    HARNESS_ENV=()

    case "$HARNESS" in
        claude)
            HARNESS_CMD=(claude -p)
            if [[ "$access" == "full" ]]; then
                HARNESS_CMD+=(--dangerously-skip-permissions)
            fi
            if [[ -n "$model" ]]; then
                HARNESS_CMD+=(--model "$model")
            fi
            HARNESS_CMD+=(--output-format json)
            if [[ "${FAST_MODE:-false}" == "true" ]]; then
                HARNESS_CMD+=(--settings '{"fastMode":true}')
            fi
            ;;
        codex)
            HARNESS_CMD=(codex exec --json --ephemeral --skip-git-repo-check --color never -C "$project_dir")
            if [[ "$access" == "full" ]]; then
                HARNESS_CMD+=(--dangerously-bypass-approvals-and-sandbox)
            else
                HARNESS_CMD+=(-s read-only)
            fi
            if [[ -n "$model" ]]; then
                HARNESS_CMD+=(-m "$model")
            fi
            if [[ -n "$effort" ]]; then
                HARNESS_CMD+=(-c "model_reasoning_effort=\"$effort\"")
            fi
            if [[ -n "$final_file" ]]; then
                HARNESS_CMD+=(-o "$final_file")
            fi
            HARNESS_CMD+=(-)
            ;;
        opencode)
            HARNESS_CMD=(opencode run --format json --dir "$project_dir")
            if [[ "$access" == "full" ]]; then
                HARNESS_CMD+=(--auto)
            else
                HARNESS_ENV+=("OPENCODE_CONFIG_CONTENT=$(_harness_opencode_restricted_config)")
            fi
            if [[ -n "$model" ]]; then
                HARNESS_CMD+=(-m "$model")
            fi
            if [[ -n "$effort" ]]; then
                HARNESS_CMD+=(--variant "$effort")
            fi
            ;;
        *)
            log_error "harness_build_cmd: harness not resolved"
            return 1
            ;;
    esac
    return 0
}

# harness_interactive_cmd <model> <prompt_text>
# Argv for a TUI session seeded with a prompt (Jeeroy's Q&A). Always full access.
harness_interactive_cmd() {
    local model="$1" prompt="$2"
    local project_dir="${PROJECT_DIR:-$(pwd)}"
    HARNESS_CMD=()
    HARNESS_ENV=()

    case "$HARNESS" in
        claude)
            HARNESS_CMD=(claude --dangerously-skip-permissions)
            if [[ -n "$model" ]]; then
                HARNESS_CMD+=(--model "$model")
            fi
            if [[ "${FAST_MODE:-false}" == "true" ]]; then
                HARNESS_CMD+=(--settings '{"fastMode":true}')
            fi
            HARNESS_CMD+=("$prompt")
            ;;
        codex)
            HARNESS_CMD=(codex --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -C "$project_dir")
            if [[ -n "$model" ]]; then
                HARNESS_CMD+=(-m "$model")
            fi
            HARNESS_CMD+=("$prompt")
            ;;
        opencode)
            HARNESS_CMD=(opencode --auto)
            if [[ -n "$model" ]]; then
                HARNESS_CMD+=(-m "$model")
            fi
            HARNESS_CMD+=(--prompt "$prompt" "$project_dir")
            ;;
        *)
            log_error "harness_interactive_cmd: harness not resolved"
            return 1
            ;;
    esac
    return 0
}

# Human-readable rendering of the last built command (dry runs, debug logs)
harness_cmd_string() {
    local rendered=""
    local item
    for item in ${HARNESS_ENV[@]+"${HARNESS_ENV[@]}"}; do
        rendered+="$(printf '%q' "$item") "
    done
    for item in ${HARNESS_CMD[@]+"${HARNESS_CMD[@]}"}; do
        rendered+="$(printf '%q' "$item") "
    done
    printf '%s' "${rendered% }"
}

# ============================================================================
# EXECUTION
# ============================================================================

# Terminate the process group we launched (only if we really own it), then
# the leader itself as a fallback.
_harness_kill_tree() {
    local pid="$1"
    [[ -z "$pid" ]] && return 0
    local pgid
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [[ -n "$pgid" ]] && [[ "$pgid" == "$pid" ]]; then
        kill -TERM -- "-$pgid" 2>/dev/null || true
        sleep 2
        kill -KILL -- "-$pgid" 2>/dev/null || true
    else
        kill -TERM "$pid" 2>/dev/null || true
        sleep 2
        kill -KILL "$pid" 2>/dev/null || true
    fi
    return 0
}

# Kill whatever harness_exec is running right now (signal handlers call this)
harness_kill_current() {
    if [[ -n "$HARNESS_PID" ]]; then
        _harness_kill_tree "$HARNESS_PID"
        wait "$HARNESS_PID" 2>/dev/null || true
        HARNESS_PID=""
    fi
    return 0
}

# harness_exec <model> <access> <prompt_file> <out_file> <err_file> <final_file> [timeout]
#
# Runs one non-interactive invocation with the prompt on stdin. The child is
# launched in its own process group so a timeout kills the whole tree.
# Returns the child's exit code, or 124 on timeout. Never trips errexit
# itself, but callers must use `harness_exec ... || ec=$?`.
harness_exec() {
    local model="$1" access="$2" prompt_file="$3" out_file="$4" err_file="$5" final_file="$6"
    local timeout="${7:-900}"

    harness_build_cmd "$model" "$access" "$final_file" || return 1

    : > "$out_file"
    : > "$err_file"
    if [[ -n "$final_file" ]]; then
        : > "$final_file"
    fi

    # Job control puts the background job in its own process group
    set -m
    env ${HARNESS_ENV[@]+"${HARNESS_ENV[@]}"} "${HARNESS_CMD[@]}" \
        < "$prompt_file" > "$out_file" 2> "$err_file" &
    HARNESS_PID=$!
    set +m

    local elapsed=0 timed_out=false ec=0
    while kill -0 "$HARNESS_PID" 2>/dev/null; do
        if [[ $elapsed -ge $timeout ]]; then
            timed_out=true
            _harness_kill_tree "$HARNESS_PID"
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    wait "$HARNESS_PID" 2>/dev/null || ec=$?
    HARNESS_PID=""

    if [[ "$timed_out" == "true" ]]; then
        return 124
    fi
    return "$ec"
}

# ============================================================================
# RESULT PARSING
# ============================================================================

_harness_reset_result() {
    HARNESS_TEXT=""
    HARNESS_TEXT_OK=false
    HARNESS_COST_USD=""
    HARNESS_TOKENS_IN=""
    HARNESS_TOKENS_OUT=""
    HARNESS_USAGE_COMPLETE=false
    HARNESS_ERRORS=""
    HARNESS_MALFORMED_LINES=0
}

# Append a line to HARNESS_ERRORS (skips empty input)
_harness_add_error() {
    local msg="$1"
    [[ -z "$msg" ]] && return 0
    if [[ -n "$HARNESS_ERRORS" ]]; then
        HARNESS_ERRORS+=$'\n'"$msg"
    else
        HARNESS_ERRORS="$msg"
    fi
    return 0
}

# Fallback when nothing parsed: pull obviously error-looking lines out of raw
# text so rate-limit detection still works on a crashed/legacy invocation.
_harness_scan_raw_errors() {
    local file="$1"
    [[ -s "$file" ]] || return 0
    local lines
    lines=$(grep -iE 'rate.?limit|(^|[^0-9])429([^0-9]|$)|usage limit|hit your [a-z ]*limit|your limit will reset|quota (exceeded|reached)|exceeded[a-z ]* quota|insufficient_quota|overloaded|api.?error|server.?error|unauthorized|forbidden|not logged in|authentication|ECONNRESET|ECONNREFUSED|Connection refused|Unable to connect|ENOTFOUND|ETIMEDOUT|EAI_AGAIN|fetch failed|network is unreachable' "$file" 2>/dev/null | head -5 || true)
    local line
    while IFS= read -r line; do
        _harness_add_error "$line"
    done <<< "$lines"
    return 0
}

# Number of lines in a file; 0 when it is empty or missing. (`grep -c` prints
# 0 AND exits 1 on an empty file, so `$(grep -c … || echo 0)` yields "0\n0"
# and the arithmetic on it aborts the script.)
_harness_count_lines() {
    local n
    n=$(grep -c '' "$1" 2>/dev/null || true)
    printf '%s' "${n:-0}"
}

# Reduce a JSONL event stream to the events the parser needs, line by line.
# Codex and OpenCode embed every command's output in the stream, so a long
# iteration (docker builds, test suites) can produce hundreds of MB; slurping
# that into one jq string wedged the loop for an hour once. Prints the count
# of parseable events and the type of the last one on stdout ("<n> <type>").
# Usage: _harness_reduce_stream <in_file> <out_file> <jq select expression>
_harness_reduce_stream() {
    local in_file="$1" reduced="$2" keep="$3"
    jq -cR "fromjson? | select($keep)" "$in_file" > "$reduced" 2>/dev/null || true
    local counted
    counted=$(jq -rR 'fromjson? | (.type // "-")' "$in_file" 2>/dev/null | awk 'END { printf "%d %s", NR, ($0 == "" ? "-" : $0) }' || true)
    printf '%s' "${counted:-0 -}"
}

# Keep only the tail of the final response. Everything the LOOP parses (status
# block, signals) sits at the end, and every "$HARNESS_TEXT" expansion of a
# huge string costs real time in bash. Not applied by harness_parse_result:
# callers that need the whole response (generated specs, plan reviews) would
# silently lose the beginning of it.
harness_cap_text() {
    local cap="${WALPH_OUTPUT_CAP:-200000}"
    # Canonical decimal of at most 12 digits: bash reads 08 as invalid octal,
    # and a value past 2^63 wraps negative, which would empty the response
    [[ "$cap" =~ ^[1-9][0-9]{0,11}$ ]] || cap=200000
    if [[ "$cap" -gt 0 ]] && [[ ${#HARNESS_TEXT} -gt $cap ]]; then
        HARNESS_TEXT="${HARNESS_TEXT: -$cap}"
    fi
    return 0
}

# Scratch file of the parse in progress, so an interrupted run can remove it
# (callers' cleanup handlers call harness_cleanup_scratch)
HARNESS_SCRATCH_FILE=""

harness_cleanup_scratch() {
    if [[ -n "$HARNESS_SCRATCH_FILE" ]]; then
        rm -f -- "$HARNESS_SCRATCH_FILE" 2>/dev/null || true
        HARNESS_SCRATCH_FILE=""
    fi
    return 0
}

_harness_parse_claude() {
    local out_file="$1"
    if ! jq -e . "$out_file" >/dev/null 2>&1; then
        HARNESS_MALFORMED_LINES=1
        _harness_scan_raw_errors "$out_file"
        return 0
    fi
    local summary
    summary=$(jq -c '{
        last: (.result // ""),
        cost: (.total_cost_usd // null),
        in: (if .usage then ((.usage.input_tokens // 0) + (.usage.cache_creation_input_tokens // 0) + (.usage.cache_read_input_tokens // 0)) else null end),
        out: (.usage.output_tokens // null),
        is_error: (.is_error // false),
        subtype: (.subtype // "")
    }' "$out_file")

    HARNESS_TEXT=$(jq -r '.last' <<< "$summary")
    HARNESS_COST_USD=$(jq -r '.cost // empty' <<< "$summary")
    HARNESS_TOKENS_IN=$(jq -r '.in // empty' <<< "$summary")
    HARNESS_TOKENS_OUT=$(jq -r '.out // empty' <<< "$summary")
    HARNESS_USAGE_COMPLETE=true

    if [[ "$(jq -r '.is_error' <<< "$summary")" == "true" ]]; then
        _harness_add_error "claude: $(jq -r '.subtype' <<< "$summary"): ${HARNESS_TEXT:0:300}"
        HARNESS_TEXT_OK=false
    elif [[ -n "$HARNESS_TEXT" ]]; then
        HARNESS_TEXT_OK=true
    fi
    return 0
}

_harness_parse_codex() {
    local out_file="$1" final_file="${2:-}"
    local total_lines parsed_lines
    total_lines=$(_harness_count_lines "$out_file")

    local reduced counted
    reduced=$(mktemp)
    HARNESS_SCRATCH_FILE="$reduced"
    counted=$(_harness_reduce_stream "$out_file" "$reduced" \
        '.type == "turn.completed" or .type == "turn.failed" or .type == "error" or (.type == "item.completed" and ((.item.type // "") == "agent_message"))')
    parsed_lines="${counted%% *}"

    local summary
    summary=$(jq -cRs '
        [ split("\n")[] | select(length > 0) | fromjson? ] as $ev
        | ($ev | map(select(.type == "turn.completed")) | last | .usage // {}) as $u
        | {
            last: ($ev | map(select(.type == "item.completed" and (.item.type // "") == "agent_message") | (.item.text // "")) | last // ""),
            in: ($u.input_tokens // null),
            out: ($u.output_tokens // null),
            complete: (($ev | map(select(.type == "turn.completed")) | length) > 0),
            errors: (
                ($ev | map(select(.type == "turn.failed")
                    | (.error | if type == "object" then (.message // tostring) else tostring end)))
                + ($ev | map(select(.type == "error")
                    | (.message // (.error | if type == "object" then (.message // tostring) else tostring end))))
            )
        }' "$reduced" 2>/dev/null || echo '{"last":"","in":null,"out":null,"complete":false,"errors":[]}')
    harness_cleanup_scratch

    HARNESS_MALFORMED_LINES=$(( total_lines - parsed_lines ))
    [[ $HARNESS_MALFORMED_LINES -lt 0 ]] && HARNESS_MALFORMED_LINES=0

    # The final message file is the authoritative response; the JSONL stream
    # may contain intermediate assistant messages.
    if [[ -n "$final_file" ]] && [[ -s "$final_file" ]]; then
        HARNESS_TEXT=$(cat "$final_file")
    else
        HARNESS_TEXT=$(jq -r '.last' <<< "$summary")
    fi
    HARNESS_TOKENS_IN=$(jq -r '.in // empty' <<< "$summary")
    HARNESS_TOKENS_OUT=$(jq -r '.out // empty' <<< "$summary")
    HARNESS_USAGE_COMPLETE=$(jq -r '.complete' <<< "$summary")

    local err
    while IFS= read -r err; do
        _harness_add_error "codex: $err"
    done < <(jq -r '.errors[]' <<< "$summary")

    if [[ -n "$HARNESS_TEXT" ]]; then
        HARNESS_TEXT_OK=true
    fi
    if [[ $parsed_lines -eq 0 ]]; then
        _harness_scan_raw_errors "$out_file"
    fi
    return 0
}

_harness_parse_opencode() {
    local out_file="$1"
    local total_lines parsed_lines
    total_lines=$(_harness_count_lines "$out_file")

    local reduced counted last_type
    reduced=$(mktemp)
    HARNESS_SCRATCH_FILE="$reduced"
    counted=$(_harness_reduce_stream "$out_file" "$reduced" \
        '.type == "text" or .type == "step_finish" or .type == "error"')
    parsed_lines="${counted%% *}"
    last_type="${counted#* }"

    local summary
    summary=$(jq -cRs --arg last_type "$last_type" '
        [ split("\n")[] | select(length > 0) | fromjson? ] as $ev
        | ($ev | map(select(.type == "text"))) as $texts
        | ($texts | map(.part.messageID) | last) as $lastmsg
        | ($ev | map(select(.type == "step_finish"))) as $steps
        | {
            last: ($texts | map(select(.part.messageID == $lastmsg) | (.part.text // "")) | join("\n")),
            in: ($steps | map(.part.tokens.input // 0) | if length > 0 then add else null end),
            out: ($steps | map(.part.tokens.output // 0) | if length > 0 then add else null end),
            cost: ($steps | map(.part.cost // 0) | if length > 0 then add else null end),
            complete: (($steps | length) > 0 and ($last_type == "step_finish") and (($steps | last | .part.reason // "") == "stop")),
            errors: ($ev | map(select(.type == "error")
                | ((.error.name // "Error") + ": " + (.error.data.message // (.error | tostring)))))
        }' "$reduced" 2>/dev/null || echo '{"last":"","in":null,"out":null,"cost":null,"complete":false,"errors":[]}')
    harness_cleanup_scratch

    HARNESS_MALFORMED_LINES=$(( total_lines - parsed_lines ))
    [[ $HARNESS_MALFORMED_LINES -lt 0 ]] && HARNESS_MALFORMED_LINES=0

    HARNESS_TEXT=$(jq -r '.last' <<< "$summary")
    HARNESS_TOKENS_IN=$(jq -r '.in // empty' <<< "$summary")
    HARNESS_TOKENS_OUT=$(jq -r '.out // empty' <<< "$summary")
    HARNESS_COST_USD=$(jq -r '.cost // empty' <<< "$summary")
    HARNESS_USAGE_COMPLETE=$(jq -r '.complete' <<< "$summary")

    local err
    while IFS= read -r err; do
        _harness_add_error "opencode: $err"
    done < <(jq -r '.errors[]' <<< "$summary")

    if [[ -n "$HARNESS_TEXT" ]]; then
        HARNESS_TEXT_OK=true
    fi
    if [[ $parsed_lines -eq 0 ]]; then
        _harness_scan_raw_errors "$out_file"
    fi
    return 0
}

# harness_parse_result <out_file> <err_file> [final_file]
# Fills the HARNESS_* result globals from the files harness_exec wrote.
# Token columns mean "all input the model saw" and "all output": Claude's
# cache-creation/read tokens are added to its input count so the figure is
# comparable with Codex (whose input_tokens already include cached input)
# and OpenCode (summed over steps).
harness_parse_result() {
    local out_file="$1" err_file="$2" final_file="${3:-}"
    _harness_reset_result

    case "$HARNESS" in
        claude)   _harness_parse_claude "$out_file" ;;
        codex)    _harness_parse_codex "$out_file" "$final_file" ;;
        opencode) _harness_parse_opencode "$out_file" ;;
        *)        log_error "harness_parse_result: harness not resolved"; return 1 ;;
    esac

    # stderr is a diagnostics channel, and the structured errors drive
    # rate-limit handling and the breaker's same-error counter — so a line
    # joins them only when it names an API/CLI failure, not whenever it
    # contains a word like "error" or a number like 429. ("warning: mcp server
    # listening on port 9429" and "SomeTool: error: cannot write cache quota
    # file" must not stop a healthy run.) Three groups:
    #   - API conditions: rate limits, caps, overload, auth
    #   - connection failures (see check_connection_error)
    #   - lines that START with error/fatal/panic, or carry an ERROR log level
    if [[ -s "$err_file" ]]; then
        local lines line
        lines=$( { grep -iE 'rate.?limit|rate_limit_error|(^|[^0-9])429([^0-9]|$)|too many requests|usage limit|hit your [a-z ]*limit|your limit will reset|quota (exceeded|reached)|exceeded[a-z ]* quota|insufficient_quota|overloaded|unauthorized|forbidden|not logged in|authentication (failed|error)|invalid api key|ECONNRESET|ECONNREFUSED|ConnectionRefused|Connection dropped|Connection refused|Unable to connect|ENOTFOUND|ETIMEDOUT|EAI_AGAIN|fetch failed|network is unreachable|CERTIFICATE_VERIFICATION_ERROR|^[[:space:]]*(error|fatal|panic)([^[:alnum:]_]|$)' "$err_file" 2>/dev/null || true
                   grep -E '(^|[[:space:]])ERROR([[:space:]:]|$)' "$err_file" 2>/dev/null || true
                 } | grep -v 'Shell cwd was reset' | awk '!seen[$0]++' | head -5 || true)
        while IFS= read -r line; do
            _harness_add_error "$line"
        done <<< "$lines"
    fi
    return 0
}

# One-line usage summary for logs: "$0.0123" or "1200/340 tokens" or "usage unknown"
harness_usage_summary() {
    if [[ -n "$HARNESS_COST_USD" ]]; then
        printf 'cost $%s' "$HARNESS_COST_USD"
    elif [[ -n "$HARNESS_TOKENS_IN" ]] || [[ -n "$HARNESS_TOKENS_OUT" ]]; then
        printf 'tokens in/out %s/%s' "${HARNESS_TOKENS_IN:-?}" "${HARNESS_TOKENS_OUT:-?}"
    else
        printf 'usage unknown'
    fi
    if [[ "$HARNESS_USAGE_COMPLETE" != "true" ]]; then
        printf ' (stream incomplete)'
    fi
}
