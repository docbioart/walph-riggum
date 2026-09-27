#!/usr/bin/env bash
# Fake agent CLI for integration tests. Symlinked as claude, codex, and
# opencode; the basename decides the output format. Behaviour comes from
# FAKE_SCENARIO (default: pipeline) and the prompt it reads on stdin.
#
#   pipeline      answer like a real agent would for whichever prompt it got
#                 (Jeeroy analysis / spec generation, plan, plan review,
#                 reconciliation, build) so whole tool chains can be exercised
#   nonzero       print an error, exit 3
#   error_event   emit a structured rate-limit error, exit 0
#   hang          spawn a child `sleep` and hang (for timeout tests)
#   two_blocks    final text has a LOW block then a HIGH/EXIT block
#   truncated     stop mid-way through the event stream
#   no_final      events but no assistant text at all
#   prose_429     final text talks about "429" and "rate limit" (no error)
#   stuck         final text carries the RALPH_STUCK signal
#   silent_fail   write nothing at all, exit 3 (crash / auth failure)
#   exit2         usage error on stderr, exit 2 (the code the loop reserves)
#   stderr_noise  a normal answer plus harmless stderr lines that merely
#                 contain "error", "quota" or a number with 429 in it
#   net_down_once first call: connection refused, exit 1; later calls: pipeline
#                 (state in FAKE_NET_MARKER)
#
# Env: FAKE_PROJECT_DIR (where plan/spec files live), FAKE_ARGV_LOG (append
# argv here), FAKE_REVIEW=bad (plan review emits no block),
# FAKE_HANG_MARKER (path the hung child sleeps on, for pkill checks).
set -u

me=$(basename "$0")
scenario="${FAKE_SCENARIO:-pipeline}"
project="${FAKE_PROJECT_DIR:-$PWD}"

if [[ -n "${FAKE_ARGV_LOG:-}" ]]; then
    printf '%s %s\n' "$me" "$*" >> "$FAKE_ARGV_LOG"
fi

# Honour the flags that change where things go
final_file=""
prev=""
for arg in "$@"; do
    case "$prev" in
        -o|--output-last-message) final_file="$arg" ;;
        -C|--cd|--dir) project="$arg" ;;
    esac
    prev="$arg"
done

prompt=$(cat)

status_block() {  # <level> <exit> <remaining>
    printf 'RALPH_STATUS\ncompletion_level: %s\ntasks_remaining: %s\ncurrent_task: fake\nEXIT_SIGNAL: %s\nRALPH_STATUS_END\n' "$1" "$3" "$2"
}

# Decide what a "real" agent would answer for this prompt
pipeline_text() {
    if [[ "$prompt" == *"Jeeroy Lenkins - Document Analysis"* ]]; then
        printf '===ANALYSIS===\nproject_type: cli\nproject_description: Hello CLI\nstack_suggestion: node\nfeature_count: 1\n\nFEATURES:\n1. Hello: prints hello\n\nTECHNICAL_DETAILS:\n- none\n\nQUESTIONS:\n1. none\n\nPROPOSED_SPECS:\n1. hello.md: hello feature | Dependencies: none\n===ANALYSIS_END===\n'
    elif [[ "$prompt" == *"Interactive Q&A and Spec Generation"* ]]; then
        printf '===SPEC_FILE: hello.md===\n# Feature: Hello\n\n## Overview\nPrint hello.\n\n## Requirements\n### Must Have\n1. node hello.js prints hello\n\n## Acceptance Criteria\n- [ ] node hello.js prints hello\n\n## Examples\n### Example 1\nInput: node hello.js\nOutput: hello\n===SPEC_FILE_END===\n'
    elif [[ "$prompt" == *"Plan Review Mode"* ]]; then
        if [[ "${FAKE_REVIEW:-ok}" == "bad" ]]; then
            printf 'I looked at the plan and it seems fine but I forgot the block.\n'
        else
            printf 'Reviewed.\n===PLAN_REVIEW===\nverdict: REVISE\nsummary: one gap\n\n1. [SEVERITY: MEDIUM] Missing .env.example task — Spec: hello.md. Task: none. Suggested change: add a setup task.\n===PLAN_REVIEW_END===\n'
        fi
    elif [[ "$prompt" == *"RECONCILIATION PASS"* ]]; then
        printf '\n## Dispositions\n1. REJECTED — the hello CLI has no configuration, so .env.example is not needed.\n' >> "$project/PLAN_REVIEW.md"
        printf 'Reconciled the review.\n'
        status_block HIGH true 1
    elif [[ "$prompt" == *"PLANNING mode"* ]]; then
        printf '# Implementation Plan\n\n## Tasks\n\n- [ ] Task 1.1: Create hello.js [spec: hello.md] (Done when: node hello.js prints hello)\n' > "$project/IMPLEMENTATION_PLAN.md"
        printf 'Wrote the plan.\n'
        status_block HIGH true 1
    elif [[ "$prompt" == *"BUILDING mode"* ]]; then
        printf 'console.log("hello")\n' > "$project/hello.js"
        sed -i.bak 's/^- \[ \] Task 1.1/- [x] Task 1.1/' "$project/IMPLEMENTATION_PLAN.md" && rm -f "$project/IMPLEMENTATION_PLAN.md.bak"
        (cd "$project" && git add -A >/dev/null 2>&1 && git commit -qm "feat: hello" >/dev/null 2>&1) || true
        printf 'Built hello.js.\n'
        status_block HIGH true 0
    elif [[ "$prompt" == *"VERIFY mode"* ]]; then
        sed -i.bak 's/^- \[ \] node hello.js/- [x] node hello.js/' "$project/specs/hello.md" 2>/dev/null && rm -f "$project/specs/hello.md.bak"
        printf 'Verified.\n'
        status_block HIGH true 0
    else
        printf 'OK\n'
        status_block MEDIUM false 1
    fi
}

case "$scenario" in
    pipeline)   text=$(pipeline_text) ;;
    two_blocks) text=$(printf 'Draft:\n'; status_block LOW false 3; printf 'Final:\n'; status_block HIGH true 0) ;;
    prose_429)  text=$(printf 'I improved the 429 rate limit handling and the retry on rate_limit_error.\n'; status_block MEDIUM false 2) ;;
    stuck)      text=$(printf 'RALPH_STUCK\nReason: the spec contradicts itself\n'; status_block LOW false 2) ;;
    no_final)   text="" ;;
    silent_fail) exit 3 ;;
    exit2)
        echo "usage: bad flag" >&2
        exit 2
        ;;
    stderr_noise)
        echo "warning: mcp server listening on port 9429" >&2
        echo "DVTDeviceOperation: error: unable to write cache quota file" >&2
        text=$(pipeline_text)
        ;;
    net_down_once)
        if [[ ! -e "${FAKE_NET_MARKER:?}" ]]; then
            : > "$FAKE_NET_MARKER"
            echo "request to the API failed, reason: connect ECONNREFUSED 127.0.0.1:443" >&2
            exit 1
        fi
        text=$(pipeline_text)
        ;;
    hang)
        sleep 300 &
        echo $! > "${FAKE_HANG_MARKER:-/dev/null}"
        sleep 300
        exit 0
        ;;
    nonzero)
        echo "fatal: something broke" >&2
        exit 3
        ;;
    *) text="unknown scenario" ;;
esac

emit_claude() {
    if [[ "$scenario" == "error_event" ]]; then
        jq -n '{type:"result",subtype:"error_during_execution",is_error:true,result:"API Error: 429 rate_limit_error: You have hit your usage limit",total_cost_usd:0,usage:{input_tokens:10,output_tokens:0}}'
        return
    fi
    if [[ "$scenario" == "truncated" ]]; then printf '{"type":"result","subtype":"succ'; return; fi
    jq -n --arg t "$text" '{type:"result",subtype:"success",is_error:false,result:$t,total_cost_usd:0.0123,usage:{input_tokens:1000,cache_read_input_tokens:500,output_tokens:200}}'
}

emit_codex() {
    echo '{"type":"thread.started","thread_id":"fake"}'
    echo '{"type":"turn.started"}'
    if [[ "$scenario" == "error_event" ]]; then
        echo '{"type":"turn.failed","error":{"message":"Rate limit reached for gpt-6-astra: please retry after 20s (429)"}}'
        return
    fi
    if [[ "$scenario" == "truncated" ]]; then printf '{"type":"item.completed","item":{"id":"item_1","ty'; return; fi
    echo '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Working on it (intermediate message that must not be treated as final)."}}'
    if [[ -n "$text" ]]; then
        jq -cn --arg t "$text" '{type:"item.completed",item:{id:"item_1",type:"agent_message",text:$t}}'
        if [[ -n "$final_file" ]]; then printf '%s' "$text" > "$final_file"; fi
    fi
    echo '{"type":"turn.completed","usage":{"input_tokens":2000,"cached_input_tokens":1500,"output_tokens":300,"reasoning_output_tokens":50}}'
}

emit_opencode() {
    echo '{"type":"step_start","timestamp":1,"sessionID":"ses_fake","part":{"id":"p0","messageID":"msg_1","type":"step-start"}}'
    if [[ "$scenario" == "error_event" ]]; then
        echo '{"type":"error","timestamp":2,"sessionID":"ses_fake","error":{"name":"APIError","data":{"message":"Rate limit exceeded"}}}'
        return
    fi
    echo '{"type":"text","timestamp":2,"sessionID":"ses_fake","part":{"id":"p1","messageID":"msg_1","type":"text","text":"Working on it (earlier message)."}}'
    echo '{"type":"step_finish","timestamp":3,"sessionID":"ses_fake","part":{"id":"p2","messageID":"msg_1","type":"step-finish","reason":"tool-calls","tokens":{"total":100,"input":80,"output":20,"reasoning":0,"cache":{"read":0,"write":0}},"cost":0.001}}'
    if [[ "$scenario" == "truncated" ]]; then printf '{"type":"text","timestamp":4,"sess'; return; fi
    if [[ -n "$text" ]]; then
        jq -cn --arg t "$text" '{type:"text",timestamp:4,sessionID:"ses_fake",part:{id:"p3",messageID:"msg_2",type:"text",text:$t}}'
    fi
    echo '{"type":"step_finish","timestamp":5,"sessionID":"ses_fake","part":{"id":"p4","messageID":"msg_2","type":"step-finish","reason":"stop","tokens":{"total":300,"input":250,"output":50,"reasoning":0,"cache":{"read":0,"write":0}},"cost":0.002}}'
}

case "$me" in
    claude)   emit_claude ;;
    codex)    emit_codex ;;
    opencode) emit_opencode ;;
    *) echo "fake-agent: unknown identity $me" >&2; exit 2 ;;
esac
exit 0
