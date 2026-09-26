#!/usr/bin/env bash
# Integration tests: drive walph/jeeroy end to end with the fake agent CLIs
# in tests/fake-bins (no real model is ever called). Covers the failure
# paths the parser tests can't: nonzero exits, timeouts with children,
# misleading prose, multiple status blocks, config precedence, plan review
# validation, and Jeeroy's build gate.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export PATH="$ROOT/tests/fake-bins:$PATH"
WORK=$(mktemp -d)
# Keep the work dir for inspection when something fails (or KEEP_WORK=1)
cleanup_work() {
    if [[ "${KEEP_WORK:-0}" == "1" ]] || [[ "${FAIL:-0}" -gt 0 ]]; then
        echo "work dir kept: $WORK"
    else
        rm -rf "${WORK:?}"
    fi
}
trap cleanup_work EXIT

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
expect_contains()     { if grep -q -- "$3" "$2"; then ok; else bad "$1: missing [$3] in $2"; fi; }
expect_not_contains() { if grep -q -- "$3" "$2"; then bad "$1: unexpected [$3] in $2"; else ok; fi; }
expect_eq()           { if [[ "$2" == "$3" ]]; then ok; else bad "$1: expected [$2] got [$3]"; fi; }
expect_file()         { if [[ -e "$2" ]]; then ok; else bad "$1: missing file $2"; fi; }
expect_no_file()      { if [[ -e "$2" ]]; then bad "$1: unexpected file $2"; else ok; fi; }

# A fresh Walph project with one spec and one open task; prints its path
# (runs in a $(...) subshell, so it cannot rely on a shared counter)
make_project() {
    local dir name
    dir=$(mktemp -d "$WORK/proj.XXXXXX")
    name=$(basename "$dir")
    (cd "$WORK" && "$ROOT/walph.sh" init "$name" --template cli --stack node >/dev/null 2>&1)
    printf '# Feature: Hello\n\n## Overview\nPrint hello.\n\n## Requirements\n### Must Have\n1. node hello.js prints hello\n\n## Acceptance Criteria\n- [ ] node hello.js prints hello\n\n## Examples\n### Example 1\nInput: node hello.js\nOutput: hello\n' > "$dir/specs/hello.md"
    printf '\n- [ ] Task 1.1: Create hello.js [spec: hello.md] (Done when: node hello.js prints hello)\n' >> "$dir/IMPLEMENTATION_PLAN.md"
    (cd "$dir" && git add -A >/dev/null && git commit -qm "spec and plan" >/dev/null)
    echo "$dir"
}

# run_walph <project> <outfile> <args...>  — sets EC
run_walph() {
    local dir="$1" out="$2"; shift 2
    EC=0
    (cd "$dir" && WALPH_SKIP_VERIFY="${WALPH_SKIP_VERIFY:-true}" FAKE_PROJECT_DIR="$dir" "$ROOT/walph.sh" "$@") > "$out" 2>&1 < /dev/null || EC=$?
}

# ---------------------------------------------------------------- build completes on every harness
for h in claude codex opencode; do
    p=$(make_project); out="$WORK/build-$h.txt"
    FAKE_SCENARIO=pipeline run_walph "$p" "$out" build --harness "$h" --max-iterations 3
    expect_eq "build/$h: exit 0" 0 "$EC"
    expect_contains "build/$h: completed" "$out" "All work completed!"
    expect_contains "build/$h: final text shown, not intermediate" "$out" "Built hello.js"
    expect_not_contains "build/$h: intermediate message not treated as final" "$out" "must not be treated as final"
    expect_contains "build/$h: plan checked" "$p/IMPLEMENTATION_PLAN.md" '- \[x\] Task 1.1'
    csv=$(ls "$p"/.walph/logs/*_summary.csv | head -1)
    expect_contains "build/$h: csv header" "$csv" "timestamp,iteration,mode,harness,model,duration_seconds,cost_usd,tokens_in,tokens_out,usage_complete,status"
    case "$h" in
        claude)   expect_contains "build/claude: cost logged" "$csv" ",build,claude,sonnet,.*,0.0123,1000,200,true," ;;
        codex)    expect_contains "build/codex: tokens, no cost" "$csv" ",build,codex,gpt-5.6-sol,.*,,2000,300,true," ;;
        opencode) expect_contains "build/opencode: cost summed" "$csv" ",build,opencode,default,.*,0.003,330,70,true," ;;
    esac
done

# ---------------------------------------------------------------- nonzero exit does not kill the loop
p=$(make_project); out="$WORK/nonzero.txt"
FAKE_SCENARIO=nonzero run_walph "$p" "$out" build --max-iterations 2
expect_contains "nonzero: reported" "$out" "exited with code 3"
expect_contains "nonzero: second iteration still ran" "$out" "Iteration 2 / 2"
expect_contains "nonzero: loop ended normally" "$out" "Maximum iterations (2) reached"
expect_contains "nonzero: handoff note mentions the exit" "$p/.walph/state/last_iteration_note" "exited with code 3"

# ---------------------------------------------------------------- timeout kills the agent's child too
p=$(make_project); out="$WORK/timeout.txt"
FAKE_SCENARIO=hang FAKE_HANG_MARKER="$WORK/hangpid" WALPH_ITERATION_TIMEOUT=3 run_walph "$p" "$out" build --max-iterations 1
expect_contains "timeout: reported" "$out" "timed out after 3s"
expect_not_contains "timeout: no completion" "$out" "Completion signal received"
child=$(cat "$WORK/hangpid" 2>/dev/null || echo "")
if [[ -n "$child" ]] && kill -0 "$child" 2>/dev/null; then
    bad "timeout: child process $child survived"; kill -9 "$child" 2>/dev/null || true
else
    ok
fi

# ---------------------------------------------------------------- prose about 429 is not a rate limit
p=$(make_project); out="$WORK/prose.txt"
FAKE_SCENARIO=prose_429 run_walph "$p" "$out" build --max-iterations 1
expect_not_contains "prose_429: no rate-limit handler" "$out" "API rate limit detected"
expect_contains "prose_429: status parsed" "$out" "Completion: MEDIUM"

# ---------------------------------------------------------------- structured rate-limit errors are
for h in claude codex opencode; do
    p=$(make_project); out="$WORK/ratelimit-$h.txt"
    FAKE_SCENARIO=error_event run_walph "$p" "$out" build --harness "$h" --max-iterations 2
    expect_contains "error_event/$h: rate limit detected" "$out" "API rate limit detected"
    expect_contains "error_event/$h: non-interactive choice exits" "$out" "Exit requested by user"
    expect_not_contains "error_event/$h: no second iteration" "$out" "Iteration 2 / 2"
done

# ---------------------------------------------------------------- last status block wins (verify has no ground truth)
p=$(make_project); out="$WORK/twoblocks.txt"
FAKE_SCENARIO=two_blocks run_walph "$p" "$out" verify --max-iterations 2
expect_contains "two_blocks: completion" "$out" "Completion signal received"
expect_not_contains "two_blocks: stopped after one" "$out" "Iteration 2 / 2"

# ---------------------------------------------------------------- no final response, no completion
p=$(make_project); out="$WORK/nofinal.txt"
FAKE_SCENARIO=no_final run_walph "$p" "$out" verify --max-iterations 1
expect_contains "no_final: warned" "$out" "No final response"
expect_not_contains "no_final: no completion" "$out" "Completion signal received"

# ---------------------------------------------------------------- truncated stream survives
for h in claude codex opencode; do
    p=$(make_project); out="$WORK/trunc-$h.txt"
    FAKE_SCENARIO=truncated run_walph "$p" "$out" verify --harness "$h" --max-iterations 1
    expect_eq "truncated/$h: loop finishes cleanly" 0 "$EC"
    expect_not_contains "truncated/$h: no completion" "$out" "Completion signal received"
done

# ---------------------------------------------------------------- stuck signal stops the loop
p=$(make_project); out="$WORK/stuck.txt"
FAKE_SCENARIO=stuck run_walph "$p" "$out" build --max-iterations 3
expect_eq "stuck: exit 1" 1 "$EC"
expect_contains "stuck: reported" "$out" "signaled it is stuck"
expect_not_contains "stuck: no second iteration" "$out" "Iteration 2 / 3"

# ---------------------------------------------------------------- config precedence and quoting
p=$(make_project); out="$WORK/config.txt"; argv="$WORK/argv-config.log"
printf 'HARNESS=codex\nMAX_ITERATIONS=5\nMODEL_BUILD="gpt-5.6-terra"\n' >> "$p/.walph/config"
FAKE_SCENARIO=prose_429 FAKE_ARGV_LOG="$argv" run_walph "$p" "$out" build --max-iterations 1 --model gpt-5.6-luna
expect_contains "config: harness from config file" "$out" "Harness: Codex CLI (codex)"
expect_contains "config: --model beats config" "$argv" "^codex .* -m gpt-5.6-luna "
expect_not_contains "config: --max-iterations beats config" "$out" "Iteration 2 / "
p=$(make_project); out="$WORK/quoted.txt"; argv="$WORK/argv-quoted.log"
printf 'MODEL_BUILD="sonnet"\n' >> "$p/.walph/config"
FAKE_SCENARIO=prose_429 FAKE_ARGV_LOG="$argv" run_walph "$p" "$out" build --max-iterations 1
expect_contains "config: quoted model value unquoted" "$argv" "^claude .* --model sonnet "
p=$(make_project); out="$WORK/alias.txt"
printf 'HARNESS=codex\nMODEL_BUILD="sonnet"\n' >> "$p/.walph/config"
FAKE_SCENARIO=prose_429 run_walph "$p" "$out" build --max-iterations 1
expect_contains "config: inherited claude alias falls back with a warning" "$out" "is a Claude model; using the codex default for build: gpt-5.6-sol"
out="$WORK/alias-flag.txt"
FAKE_SCENARIO=prose_429 run_walph "$p" "$out" build --max-iterations 1 --model opus
expect_eq "config: explicit --model opus on codex fails fast" 1 "$EC"
expect_contains "config: explicit alias error" "$out" "is a Claude model but the harness is codex"

# ---------------------------------------------------------------- plan review
p=$(make_project); out="$WORK/review-ok.txt"
FAKE_SCENARIO=pipeline run_walph "$p" "$out" review-plan --reviewer codex
expect_eq "review-plan: exit 0" 0 "$EC"
expect_contains "review-plan: reviewer ran restricted" "$out" "reviewing IMPLEMENTATION_PLAN.md with restricted access"
expect_contains "review-plan: verdict recorded" "$p/PLAN_REVIEW.md" "verdict: REVISE"
expect_contains "review-plan: dispositions appended" "$p/PLAN_REVIEW.md" "## Dispositions"
expect_contains "review-plan: reconciled" "$out" "Plan reconciled"

p=$(make_project); out="$WORK/review-bad.txt"
FAKE_SCENARIO=pipeline FAKE_REVIEW=bad run_walph "$p" "$out" review-plan --reviewer codex:gpt-6-astra
expect_eq "review-plan bad: exit 1" 1 "$EC"
expect_contains "review-plan bad: explained" "$out" "no valid ===PLAN_REVIEW=== block"
expect_contains "review-plan bad: raw output saved" "$p/PLAN_REVIEW.md" "forgot the block"
expect_not_contains "review-plan bad: no reconciliation" "$out" "Reconciliation:"

p=$(make_project); out="$WORK/review-missing.txt"
run_walph "$p" "$out" review-plan
expect_eq "review-plan: needs --reviewer" 1 "$EC"

p=$(make_project); out="$WORK/plan-chain.txt"
FAKE_SCENARIO=pipeline run_walph "$p" "$out" plan --reviewer opencode --max-iterations 2
expect_eq "plan --reviewer: exit 0" 0 "$EC"
expect_contains "plan --reviewer: review ran after planning" "$out" "OpenCode (harness default) reviewing IMPLEMENTATION_PLAN.md"
expect_contains "plan --reviewer: dispositions" "$p/PLAN_REVIEW.md" "## Dispositions"

# ---------------------------------------------------------------- jeeroy --lfg is gated by the review
mkdir -p "$WORK/docs"; printf '# Brief\nBuild a CLI that prints hello.\n' > "$WORK/docs/brief.md"
proj="$WORK/jeeroy-bad"; out="$WORK/jeeroy-bad.txt"; EC=0
(cd "$WORK" && FAKE_SCENARIO=pipeline FAKE_REVIEW=bad FAKE_PROJECT_DIR="$proj" WALPH_SKIP_VERIFY=true "$ROOT/jeeroy.sh" ./docs --project "$proj" --skip-qa --lfg --harness claude --reviewer codex) > "$out" 2>&1 < /dev/null || EC=$?
expect_eq "jeeroy bad review: exit 1" 1 "$EC"
expect_file "jeeroy bad review: specs were generated" "$proj/specs/hello.md"
expect_contains "jeeroy bad review: planning reported as incomplete" "$out" "did not complete"
expect_no_file "jeeroy bad review: build did not run" "$proj/hello.js"

proj="$WORK/jeeroy-ok"; out="$WORK/jeeroy-ok.txt"; EC=0
(cd "$WORK" && FAKE_SCENARIO=pipeline FAKE_PROJECT_DIR="$proj" "$ROOT/jeeroy.sh" ./docs --project "$proj" --skip-qa --lfg --harness codex --reviewer claude) > "$out" 2>&1 < /dev/null || EC=$?
expect_eq "jeeroy full: exit 0" 0 "$EC"
expect_file "jeeroy full: spec" "$proj/specs/hello.md"
expect_contains "jeeroy full: plan reviewed" "$proj/PLAN_REVIEW.md" "## Dispositions"
expect_file "jeeroy full: built" "$proj/hello.js"
expect_contains "jeeroy full: verify ran and checked the spec" "$proj/specs/hello.md" '- \[x\] node hello.js'
expect_contains "jeeroy full: harness passed through to walph" "$out" "Harness: Codex CLI (codex)"

echo "runner_integration_test: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
