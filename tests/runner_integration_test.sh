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
        claude)   expect_contains "build/claude: cost logged" "$csv" ",build,claude,sonnet,.*,0.0123,1500,200,true," ;;
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

# (non-interactive runs WAIT and retry on a rate limit instead of exiting: an
# unattended overnight run must survive a cap. RATE_LIMIT_RETRY_DELAY=1 keeps
# the wait short here.)
# ---------------------------------------------------------------- structured rate-limit errors are
for h in claude codex opencode; do
    p=$(make_project); out="$WORK/ratelimit-$h.txt"
    printf 'RATE_LIMIT_RETRY_DELAY=1   # seconds\n' >> "$p/.walph/config"
    FAKE_SCENARIO=error_event run_walph "$p" "$out" build --harness "$h" --max-iterations 2
    expect_contains "error_event/$h: rate limit detected" "$out" "API rate limit detected"
    expect_contains "error_event/$h: non-interactive run waits" "$out" "non-interactive session, waiting 1s"
    expect_not_contains "error_event/$h: does not exit as if the user asked" "$out" "Exit requested by user"
    expect_contains "error_event/$h: carries on to the next iteration" "$out" "Iteration 2 / 2"
    expect_eq "error_event/$h: an unfinished run exits 3" 3 "$EC"
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
    # 3 = "ended without completing" (max iterations reached), not a crash
    expect_eq "truncated/$h: loop ends without completing, no crash" 3 "$EC"
    expect_contains "truncated/$h: reached the end of the loop" "$out" "Maximum iterations"
    expect_not_contains "truncated/$h: no completion" "$out" "Completion signal received"
done

# ---------------------------------------------------------------- an agent that writes nothing and fails
# (empty stdout used to abort the whole script with an arithmetic error)
for h in claude codex opencode; do
    p=$(make_project); out="$WORK/silent-$h.txt"
    FAKE_SCENARIO=silent_fail run_walph "$p" "$out" build --harness "$h" --max-iterations 2
    expect_not_contains "silent_fail/$h: no shell error" "$out" "syntax error"
    expect_contains "silent_fail/$h: failure is reported" "$out" "exited with code 3"
    expect_contains "silent_fail/$h: second iteration still runs" "$out" "Iteration 2 / 2"
    expect_file "silent_fail/$h: handoff note written" "$p/.walph/state/last_iteration_note"
    expect_eq "silent_fail/$h: exit 3 (not completed)" 3 "$EC"
done

# ---------------------------------------------------------------- agent exit code 2 is not "user chose to exit"
for h in claude codex opencode; do
    p=$(make_project); out="$WORK/exit2-$h.txt"
    FAKE_SCENARIO=exit2 run_walph "$p" "$out" build --harness "$h" --max-iterations 2
    expect_not_contains "exit2/$h: not mistaken for a user exit" "$out" "Exit requested by user"
    expect_contains "exit2/$h: second iteration still runs" "$out" "Iteration 2 / 2"
    expect_eq "exit2/$h: exit 3 (not completed), never 0" 3 "$EC"
done

# ---------------------------------------------------------------- harmless stderr does not stop a healthy run
for h in claude codex opencode; do
    p=$(make_project); out="$WORK/noise-$h.txt"
    FAKE_SCENARIO=stderr_noise run_walph "$p" "$out" build --harness "$h" --max-iterations 2
    expect_not_contains "stderr_noise/$h: no rate-limit handler" "$out" "API rate limit detected"
    expect_not_contains "stderr_noise/$h: no API error" "$out" "API error detected"
    expect_contains "stderr_noise/$h: completed" "$out" "All work completed!"
    expect_eq "stderr_noise/$h: exit 0" 0 "$EC"
done

# ---------------------------------------------------------------- a network outage is retried, not counted
for h in claude codex opencode; do
    p=$(make_project); out="$WORK/net-$h.txt"
    FAKE_NET_MARKER="$WORK/net-marker-$h" WALPH_CONNECTIVITY_URL="file://$ROOT/README.md" \
        FAKE_SCENARIO=net_down_once run_walph "$p" "$out" build --harness "$h" --max-iterations 1
    expect_contains "net_down/$h: outage recognised" "$out" "could not reach the API"
    expect_contains "net_down/$h: same iteration retried" "$out" "Retrying iteration 1 after connectivity pause"
    expect_not_contains "net_down/$h: iteration counter not burned" "$out" "Maximum iterations"
    expect_contains "net_down/$h: completed on the retry" "$out" "All work completed!"
    expect_eq "net_down/$h: exit 0" 0 "$EC"
done

# ---------------------------------------------------------------- an outage that never clears is booked as a failure
# (the probe says "online" but every request fails: after the retries are
# used up the iteration must reach the handoff note and the circuit breaker)
p=$(make_project); out="$WORK/net-exhausted.txt"
WALPH_CONNECTIVITY_URL="file://$ROOT/README.md" RUNNER_NET_RETRY_MAX=3 \
    FAKE_SCENARIO=net_down run_walph "$p" "$out" build --max-iterations 1
expect_contains "net exhausted: retried first" "$out" "Retrying iteration 1 after connectivity pause (retry 3)"
expect_contains "net exhausted: then counted as a failure" "$out" "counting this as a failed iteration"
expect_file "net exhausted: handoff note written" "$p/.walph/state/last_iteration_note"
expect_contains "net exhausted: the note names the error" "$p/.walph/state/last_iteration_note" "ECONNREFUSED"
expect_contains "net exhausted: circuit breaker saw the error" "$p/.walph/state/circuit_breaker.json" "ECONNREFUSED"
expect_eq "net exhausted: exit 3 (not completed)" 3 "$EC"

# ---------------------------------------------------------------- a temp dir with a space in its name
p=$(make_project); out="$WORK/tmpspace.txt"
mkdir -p "$WORK/tmp dir"; : > "$WORK/tmp"    # "$WORK/tmp" is the path word splitting would hit
(cd "$p" && TMPDIR="$WORK/tmp dir" WALPH_SKIP_VERIFY=true FAKE_PROJECT_DIR="$p" FAKE_SCENARIO=pipeline "$ROOT/walph.sh" build --max-iterations 2) > "$out" 2>&1 < /dev/null || true
expect_contains "tmp with space: build completed" "$out" "All work completed!"
expect_eq "tmp with space: no temp files left behind" 0 "$(find "$WORK/tmp dir" -type f | wc -l | tr -d ' ')"
expect_file "tmp with space: the neighbouring path was not removed" "$WORK/tmp"

# ---------------------------------------------------------------- config values with inline comments
p=$(make_project); out="$WORK/inline-comment.txt"
printf 'ITERATION_TIMEOUT=2  # seconds\nMAX_ITERATIONS="1"   # quoted\n' >> "$p/.walph/config"
marker="$WORK/inline-comment.child"
FAKE_HANG_MARKER="$marker" FAKE_SCENARIO=hang run_walph "$p" "$out" build
expect_contains "inline comment: timeout value is used" "$out" "timed out after 2s"
expect_contains "inline comment: quoted max iterations is used" "$out" "Iteration 1 / 1"
expect_not_contains "inline comment: no shell error" "$out" "syntax error"
if [[ -s "$marker" ]] && kill -0 "$(cat "$marker")" 2>/dev/null; then
    bad "inline comment: the hung agent's child survived the timeout"
    kill "$(cat "$marker")" 2>/dev/null || true
else
    ok
fi

# ---------------------------------------------------------------- a configured reviewer does not block build
p=$(make_project); out="$WORK/reviewer-gate.txt"
printf 'PLAN_REVIEWER=nosuchharness:model\n' >> "$p/.walph/config"
FAKE_SCENARIO=pipeline run_walph "$p" "$out" build --max-iterations 2
expect_eq "reviewer gate: build ignores an unusable PLAN_REVIEWER" 0 "$EC"
expect_contains "reviewer gate: build completed" "$out" "All work completed!"
FAKE_SCENARIO=pipeline run_walph "$p" "$out.plan" plan --max-iterations 2
expect_eq "reviewer gate: plan still rejects it" 1 "$EC"

# ---------------------------------------------------------------- timed-out iteration records unverified tasks
p=$(make_project); out="$WORK/unverified.txt"
cat > "$WORK/check-then-hang" <<'FAKE'
#!/usr/bin/env bash
# checks the task off, then hangs: the loop must not trust that checkbox
cat > /dev/null
sed -i.bak 's/^- \[ \] Task 1.1/- [x] Task 1.1/' "$FAKE_PROJECT_DIR/IMPLEMENTATION_PLAN.md" && rm -f "$FAKE_PROJECT_DIR/IMPLEMENTATION_PLAN.md.bak"
sleep 300
FAKE
chmod +x "$WORK/check-then-hang"; mkdir -p "$WORK/hangbin"; ln -sf "$WORK/check-then-hang" "$WORK/hangbin/claude"
(cd "$p" && PATH="$WORK/hangbin:$PATH" WALPH_SKIP_VERIFY=true FAKE_PROJECT_DIR="$p" "$ROOT/walph.sh" build --timeout 2 --max-iterations 1) > "$out" 2>&1 < /dev/null || true
expect_contains "unverified: --timeout flag is used" "$out" "timed out after 2s"
expect_file "unverified: task list written for 'walph recover'" "$p/.walph/state/unverified_tasks"
expect_contains "unverified: the task is named" "$p/.walph/state/unverified_tasks" "Task 1.1"
expect_contains "unverified: next iteration is told" "$p/.walph/state/last_iteration_note" "UNVERIFIED"

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

# ---------------------------------------------------------------- interrupting jeeroy stops the agent
# (the agent used to run inside $(...): its PID lived in a subshell, so the
# signal handler had nothing to kill and the agent carried on as an orphan)
mkdir -p "$WORK/docs"; printf '# Brief\nBuild a CLI that prints hello.\n' > "$WORK/docs/brief.md"
proj="$WORK/jeeroy-int"; out="$WORK/jeeroy-int.txt"; marker="$WORK/jeeroy-int.child"
mkdir -p "$proj"   # otherwise jeeroy asks whether to create it, and stdin is /dev/null
(cd "$WORK" && FAKE_SCENARIO=hang FAKE_HANG_MARKER="$marker" FAKE_PROJECT_DIR="$proj" \
    exec "$ROOT/jeeroy.sh" ./docs --project "$proj" --skip-qa) > "$out" 2>&1 < /dev/null &
jeeroy_pid=$!
waited=0
while [[ ! -s "$marker" ]] && [[ $waited -lt 30 ]]; do sleep 1; waited=$((waited + 1)); done
if [[ -s "$marker" ]]; then
    ok
    child=$(cat "$marker")
    # TERM, not INT: a background job of a non-interactive shell starts with
    # SIGINT ignored, so it could never see one. Both signals run the same handler.
    kill -TERM "$jeeroy_pid" 2>/dev/null || true
    waited=0
    while kill -0 "$jeeroy_pid" 2>/dev/null && [[ $waited -lt 15 ]]; do sleep 1; waited=$((waited + 1)); done
    if kill -0 "$jeeroy_pid" 2>/dev/null; then bad "jeeroy interrupt: jeeroy still running"; kill -KILL "$jeeroy_pid" 2>/dev/null || true; else ok; fi
    sleep 1
    if kill -0 "$child" 2>/dev/null; then
        bad "jeeroy interrupt: the agent's child survived as an orphan"
        kill -KILL "$child" 2>/dev/null || true
    else
        ok
    fi
    expect_contains "jeeroy interrupt: reported" "$out" "Interrupted"
else
    bad "jeeroy interrupt: the agent never started (no marker after 30s)"
    kill -KILL "$jeeroy_pid" 2>/dev/null || true
fi
wait "$jeeroy_pid" 2>/dev/null || true

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
