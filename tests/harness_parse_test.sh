#!/usr/bin/env bash
# Unit tests for lib/harness.sh parsing/command building and the status
# parser, against fixtures captured from real CLI runs. No agent is called.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FIX="$ROOT/tests/fixtures"
source "$ROOT/lib/logging.sh"
source "$ROOT/lib/harness.sh"
source "$ROOT/lib/status_parser.sh"

PASS=0
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT
EMPTY="$TMP/empty"
: > "$EMPTY"

assert_eq() {  # <name> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $1: expected [$2] got [$3]"
    fi
}
assert_contains() {  # <name> <haystack> <needle>
    if [[ "$2" == *"$3"* ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $1: [$3] not found in [${2:0:200}]"
    fi
}
assert_true() {  # <name> <exit code>
    assert_eq "$1" 0 "$2"
}

# ---------------------------------------------------------------- claude
HARNESS=claude
harness_parse_result "$FIX/claude-ok.json" "$EMPTY" ""
assert_eq "claude: text ok" true "$HARNESS_TEXT_OK"
assert_eq "claude: cost" 0.0421 "$HARNESS_COST_USD"
assert_eq "claude: tokens" "1200/340" "$HARNESS_TOKENS_IN/$HARNESS_TOKENS_OUT"
assert_eq "claude: usage complete" true "$HARNESS_USAGE_COMPLETE"
assert_eq "claude: no errors" "" "$HARNESS_ERRORS"
assert_contains "claude: status summary" "$(get_status_summary "$HARNESS_TEXT")" "Completion: MEDIUM"
rc=0; check_completion "$HARNESS_TEXT" || rc=$?
assert_eq "claude: MEDIUM is not completion" 1 "$rc"

jq -n '{type:"result",subtype:"error_during_execution",is_error:true,result:"API Error: 429 rate_limit_error: usage limit reached",total_cost_usd:0}' > "$TMP/claude-err.json"
harness_parse_result "$TMP/claude-err.json" "$EMPTY" ""
assert_eq "claude error: text not ok" false "$HARNESS_TEXT_OK"
assert_contains "claude error: errors carry the message" "$HARNESS_ERRORS" "rate_limit_error"
rc=0; check_rate_limit "$HARNESS_ERRORS" || rc=$?
assert_true "claude error: rate limit detected" "$rc"

printf '{"type":"result","subtype":"succ' > "$TMP/claude-trunc.json"
harness_parse_result "$TMP/claude-trunc.json" "$EMPTY" ""
assert_eq "claude truncated: text not ok" false "$HARNESS_TEXT_OK"
assert_eq "claude truncated: malformed counted" 1 "$HARNESS_MALFORMED_LINES"

printf 'Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"x"}}\n' > "$TMP/claude-legacy.txt"
harness_parse_result "$TMP/claude-legacy.txt" "$EMPTY" ""
rc=0; check_rate_limit "$HARNESS_ERRORS" || rc=$?
assert_true "claude legacy text: rate limit still detected" "$rc"

# ---------------------------------------------------------------- codex
HARNESS=codex
harness_parse_result "$FIX/codex-ok.jsonl" "$EMPTY" ""
assert_eq "codex: text" "OK" "$HARNESS_TEXT"
assert_eq "codex: cost unknown" "" "$HARNESS_COST_USD"
assert_eq "codex: tokens" "15283/5" "$HARNESS_TOKENS_IN/$HARNESS_TOKENS_OUT"
assert_eq "codex: usage complete" true "$HARNESS_USAGE_COMPLETE"
assert_eq "codex: config warnings are not errors" "" "$HARNESS_ERRORS"

harness_parse_result "$FIX/codex-multistep.jsonl" "$EMPTY" ""
assert_contains "codex multistep: last agent message wins" "$(printf '%s' "$HARNESS_TEXT" | head -1)" "# 1. Factual corrections"
assert_eq "codex multistep: tokens from turn.completed" "1905440/9730" "$HARNESS_TOKENS_IN/$HARNESS_TOKENS_OUT"

printf 'FINAL FROM FILE' > "$TMP/final.txt"
harness_parse_result "$FIX/codex-multistep.jsonl" "$EMPTY" "$TMP/final.txt"
assert_eq "codex: -o file beats the stream" "FINAL FROM FILE" "$HARNESS_TEXT"

head -4 "$FIX/codex-ok.jsonl" > "$TMP/codex-trunc.jsonl"; printf '{"type":"turn.compl' >> "$TMP/codex-trunc.jsonl"
harness_parse_result "$TMP/codex-trunc.jsonl" "$EMPTY" ""
assert_eq "codex truncated: usage incomplete" false "$HARNESS_USAGE_COMPLETE"
assert_eq "codex truncated: malformed counted" 1 "$HARNESS_MALFORMED_LINES"
assert_contains "codex truncated: summary says so" "$(harness_usage_summary)" "stream incomplete"

printf '{"type":"thread.started","thread_id":"x"}\n{"type":"turn.failed","error":{"message":"Rate limit reached (429)"}}\n' > "$TMP/codex-fail.jsonl"
harness_parse_result "$TMP/codex-fail.jsonl" "$EMPTY" ""
assert_eq "codex turn.failed: text not ok" false "$HARNESS_TEXT_OK"
assert_contains "codex turn.failed: error captured" "$HARNESS_ERRORS" "Rate limit reached"
rc=0; check_rate_limit "$HARNESS_ERRORS" || rc=$?
assert_true "codex turn.failed: rate limit detected" "$rc"
printf '{"type":"error","message":"stream error: overloaded"}\n' > "$TMP/codex-err.jsonl"
harness_parse_result "$TMP/codex-err.jsonl" "$EMPTY" ""
rc=0; check_api_error "$HARNESS_ERRORS" || rc=$?
assert_true "codex error event: api error detected" "$rc"

# ---------------------------------------------------------------- opencode
HARNESS=opencode
harness_parse_result "$FIX/opencode-ok.jsonl" "$EMPTY" ""
assert_contains "opencode: text" "$HARNESS_TEXT" "OK"
assert_eq "opencode: cost (local model)" 0 "$HARNESS_COST_USD"
assert_eq "opencode: tokens" "12863/4" "$HARNESS_TOKENS_IN/$HARNESS_TOKENS_OUT"
assert_eq "opencode: usage complete" true "$HARNESS_USAGE_COMPLETE"

cat > "$TMP/oc-multi.jsonl" << 'JSON'
{"type":"step_start","timestamp":1,"sessionID":"s","part":{"id":"p0","messageID":"m1","type":"step-start"}}
{"type":"text","timestamp":2,"sessionID":"s","part":{"id":"p1","messageID":"m1","type":"text","text":"Working (earlier message)"}}
{"type":"step_finish","timestamp":3,"sessionID":"s","part":{"id":"p2","messageID":"m1","type":"step-finish","reason":"tool-calls","tokens":{"total":100,"input":80,"output":20,"reasoning":0,"cache":{"read":0,"write":0}},"cost":0.001}}
{"type":"text","timestamp":4,"sessionID":"s","part":{"id":"p3","messageID":"m2","type":"text","text":"Part one."}}
{"type":"text","timestamp":5,"sessionID":"s","part":{"id":"p4","messageID":"m2","type":"text","text":"Part two."}}
{"type":"step_finish","timestamp":6,"sessionID":"s","part":{"id":"p5","messageID":"m2","type":"step-finish","reason":"stop","tokens":{"total":300,"input":250,"output":50,"reasoning":0,"cache":{"read":0,"write":0}},"cost":0.002}}
JSON
harness_parse_result "$TMP/oc-multi.jsonl" "$EMPTY" ""
assert_eq "opencode multi: only the last message is final" "Part one.
Part two." "$HARNESS_TEXT"
assert_eq "opencode multi: cost summed over steps" 0.003 "$HARNESS_COST_USD"
assert_eq "opencode multi: tokens summed over steps" "330/70" "$HARNESS_TOKENS_IN/$HARNESS_TOKENS_OUT"
assert_eq "opencode multi: complete" true "$HARNESS_USAGE_COMPLETE"

head -2 "$FIX/opencode-ok.jsonl" > "$TMP/oc-trunc.jsonl"; printf '{"type":"step_fin' >> "$TMP/oc-trunc.jsonl"
harness_parse_result "$TMP/oc-trunc.jsonl" "$EMPTY" ""
assert_eq "opencode truncated: cost unknown, not zero" "" "$HARNESS_COST_USD"
assert_eq "opencode truncated: incomplete" false "$HARNESS_USAGE_COMPLETE"

printf '{"type":"error","timestamp":1,"sessionID":"s","error":{"name":"APIError","data":{"message":"Rate limit exceeded"}}}\n' > "$TMP/oc-err.jsonl"
harness_parse_result "$TMP/oc-err.jsonl" "$EMPTY" ""
assert_eq "opencode error: message" "opencode: APIError: Rate limit exceeded" "$HARNESS_ERRORS"
rc=0; check_rate_limit "$HARNESS_ERRORS" || rc=$?
assert_true "opencode error: rate limit detected" "$rc"

# stderr joins the error channel, cwd-reset noise does not
printf 'Shell cwd was reset to /x\nError: not logged in\n' > "$TMP/err.txt"
harness_parse_result "$FIX/opencode-ok.jsonl" "$TMP/err.txt" ""
assert_eq "stderr: error line captured, noise dropped" "Error: not logged in" "$HARNESS_ERRORS"

# ---------------------------------------------------------------- status parser
two=$(printf 'RALPH_STATUS\ncompletion_level: LOW\nEXIT_SIGNAL: false\nRALPH_STATUS_END\nmore text\nRALPH_STATUS\ncompletion_level: HIGH\nEXIT_SIGNAL: true\nRALPH_STATUS_END\n')
rc=0; check_completion "$two" || rc=$?
assert_true "status: last block wins" "$rc"
one=$(printf 'RALPH_STATUS\ncompletion_level: HIGH\nEXIT_SIGNAL: true\nRALPH_STATUS_END\ntrailing\nRALPH_STATUS\ncompletion_level: LOW\nEXIT_SIGNAL: false\nRALPH_STATUS_END\n')
rc=0; check_completion "$one" || rc=$?
assert_eq "status: a later LOW block cancels an earlier HIGH" 1 "$rc"
rc=0; check_completion "no block here" || rc=$?
assert_eq "status: no block is not completion" 1 "$rc"
rc=0; check_rate_limit "" || rc=$?
assert_eq "rate limit: empty error channel is clean" 1 "$rc"

# ---------------------------------------------------------------- command building
PROJECT_DIR="/tmp/proj"
HARNESS=claude; harness_build_cmd "opus" full ""
assert_eq "cmd claude full" "claude -p --dangerously-skip-permissions --model opus --output-format json" "$(harness_cmd_string)"
harness_build_cmd "" restricted ""
assert_eq "cmd claude restricted, no model" "claude -p --output-format json" "$(harness_cmd_string)"
HARNESS=codex; REASONING_EFFORT=high harness_build_cmd "gpt-6-astra" full "/tmp/f"
assert_eq "cmd codex full" 'codex exec --json --ephemeral --skip-git-repo-check --color never -C /tmp/proj --dangerously-bypass-approvals-and-sandbox -m gpt-6-astra -c model_reasoning_effort=\"high\" -o /tmp/f -' "$(harness_cmd_string)"
harness_build_cmd "" restricted "/tmp/f"
assert_contains "cmd codex restricted" "$(harness_cmd_string)" "-s read-only"
HARNESS=opencode; harness_build_cmd "spark3fn/qwen" full ""
assert_eq "cmd opencode full" "opencode run --format json --dir /tmp/proj --auto -m spark3fn/qwen" "$(harness_cmd_string)"
harness_build_cmd "" restricted ""
assert_contains "cmd opencode restricted denies edit" "${HARNESS_ENV[0]}" '"edit":"deny"'
assert_eq "cmd opencode restricted has no --auto" "opencode run --format json --dir /tmp/proj" "${HARNESS_CMD[*]}"
OPENCODE_CONFIG_CONTENT='{"model":"x/y","permission":{"webfetch":"allow"}}' harness_build_cmd "" restricted ""
merged="${HARNESS_ENV[0]#OPENCODE_CONFIG_CONTENT=}"
assert_eq "cmd opencode restricted merges inherited config" "x/y" "$(jq -r .model <<< "$merged")"
assert_eq "cmd opencode restricted deny wins" "deny" "$(jq -r .permission.webfetch <<< "$merged")"
unset OPENCODE_CONFIG_CONTENT
harness_interactive_cmd "" "Read the file"
assert_eq "interactive opencode" "opencode --auto --prompt Read\\ the\\ file /tmp/proj" "$(harness_cmd_string)"
HARNESS=codex; harness_interactive_cmd "gpt-6-astra" "hi"
assert_eq "interactive codex" "codex --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -C /tmp/proj -m gpt-6-astra hi" "$(harness_cmd_string)"

# ---------------------------------------------------------------- resolution
assert_eq "strip quotes double" opus "$(harness_strip_quotes '"opus"')"
assert_eq "strip quotes single" opus "$(harness_strip_quotes "'opus'")"
assert_eq "strip quotes bare" opus "$(harness_strip_quotes opus)"
assert_eq "strip quotes lone quote kept" '"' "$(harness_strip_quotes '"')"

rc=0; resolve_harness "gemini" "" "" >/dev/null || rc=$?
assert_eq "resolve: unknown harness rejected" 1 "$rc"
resolve_harness "" "opencode" "codex"; assert_eq "resolve: env beats config" opencode "$HARNESS"
resolve_harness "codex" "opencode" ""; assert_eq "resolve: flag beats env" codex "$HARNESS"
resolve_harness "" "" ""; assert_eq "resolve: default claude" claude "$HARNESS"

HARNESS=codex
M='"opus"'; harness_resolve_model M plan "" "" >/dev/null
assert_eq "model: quoted claude alias from config falls back on codex" gpt-6-astra "$M"
M=""; rc=0; harness_resolve_model M build "" "opus" >/dev/null 2>&1 || rc=$?
assert_eq "model: explicit --model opus on codex is an error" 1 "$rc"
M=""; harness_resolve_model M build "" "" >/dev/null; assert_eq "model: codex build default" gpt-5.6-sol "$M"
M=""; harness_resolve_model M audit "" "" >/dev/null; assert_eq "model: codex audit default" gpt-6-astra "$M"
M=""; harness_resolve_model M build "gpt-5.6-terra" "" >/dev/null; assert_eq "model: env wins over default" gpt-5.6-terra "$M"
HARNESS=opencode; M=""; harness_resolve_model M plan "" "" >/dev/null; assert_eq "model: opencode default is the harness's own" "" "$M"
HARNESS=claude; M=""; harness_resolve_model M verify "" "" >/dev/null; assert_eq "model: claude verify default" opus "$M"

echo "harness_parse_test: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
