#!/usr/bin/env bash
# Walph Riggum - Second-model plan review
#
# One restricted (best-effort read-only) review pass over IMPLEMENTATION_PLAN.md
# by a second harness/model, written to PLAN_REVIEW.md, followed by one
# reconciliation pass in which the primary planner gives every finding a
# disposition and updates the plan. Two models get input; neither gets the
# last word silently. There is no default reviewer — this only runs when
# --reviewer or PLAN_REVIEWER is set.

PLAN_REVIEW_FILE="PLAN_REVIEW.md"

REVIEWER_HARNESS=""
REVIEWER_MODEL=""

# parse_reviewer_spec "codex:gpt-6-astra" | "claude" | "opencode:provider/model"
# Sets REVIEWER_HARNESS and REVIEWER_MODEL (model defaults per harness).
parse_reviewer_spec() {
    local spec="$1"
    REVIEWER_HARNESS="${spec%%:*}"
    REVIEWER_MODEL=""
    if [[ "$spec" == *:* ]]; then
        REVIEWER_MODEL="${spec#*:}"
    fi

    if ! harness_is_supported "$REVIEWER_HARNESS"; then
        log_error "Reviewer '$spec': unknown harness '$REVIEWER_HARNESS' (use claude, codex, or opencode, optionally :model)"
        return 1
    fi
    if [[ -z "$REVIEWER_MODEL" ]]; then
        REVIEWER_MODEL=$(harness_model_default review "$REVIEWER_HARNESS")
    elif [[ "$REVIEWER_HARNESS" != "claude" ]] && harness_is_claude_model "$REVIEWER_MODEL"; then
        log_error "Reviewer '$spec': '$REVIEWER_MODEL' is a Claude model but the reviewer harness is $REVIEWER_HARNESS"
        return 1
    fi
    return 0
}

# Validate the reviewer up front so a bad spec fails before a long plan loop
check_reviewer_ready() {
    local spec="$1"
    parse_reviewer_spec "$spec" || return 1
    harness_check_installed "$REVIEWER_HARNESS" || return 1
    return 0
}

# The last ===PLAN_REVIEW=== ... ===PLAN_REVIEW_END=== block in the text
_extract_plan_review_block() {
    printf '%s\n' "$1" | awk '
        /^[[:space:]]*===PLAN_REVIEW===[[:space:]]*$/     { buf = ""; inblock = 1; next }
        /^[[:space:]]*===PLAN_REVIEW_END===[[:space:]]*$/ { if (inblock) { last = buf }; inblock = 0; next }
        inblock                                           { buf = buf $0 "\n" }
        END                                               { printf "%s", last }
    '
}

# Pick a prompt template: project copy first, then the shipped one
_plan_review_template_path() {
    local name="$1"
    if [[ -f "$PROJECT_DIR/.walph/$name" ]]; then
        echo "$PROJECT_DIR/.walph/$name"
    elif [[ -f "$SCRIPT_DIR/templates/$name" ]]; then
        echo "$SCRIPT_DIR/templates/$name"
    else
        return 1
    fi
}

# run_plan_review <reviewer_spec>
# Returns 0 when the review (and reconciliation, if needed) completed.
run_plan_review() {
    local reviewer_spec="$1"
    parse_reviewer_spec "$reviewer_spec" || return 1

    local plan_file="$PROJECT_DIR/IMPLEMENTATION_PLAN.md"
    if [[ ! -f "$plan_file" ]] || ! grep -qE '^[[:space:]]*- \[[ x]\]' "$plan_file"; then
        log_error "IMPLEMENTATION_PLAN.md has no tasks to review — run 'walph plan' first"
        return 1
    fi
    harness_check_installed "$REVIEWER_HARNESS" || return 1

    local template
    if ! template=$(_plan_review_template_path "PROMPT_plan_review.md"); then
        log_error "Prompt template not found: PROMPT_plan_review.md"
        return 1
    fi

    echo ""
    log_info "Plan review: $(harness_display_name "$REVIEWER_HARNESS") (${REVIEWER_MODEL:-harness default}) reviewing IMPLEMENTATION_PLAN.md with restricted access"

    # Render with the same substitutions the loop uses (principles, iteration)
    local saved_mode="$MODE"
    MODE="plan-review"
    local prompt
    prompt=$(render_prompt_template "$template" 1 "$STATE_DIR")
    MODE="$saved_mode"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        local saved_harness="$HARNESS"
        HARNESS="$REVIEWER_HARNESS"
        harness_build_cmd "$REVIEWER_MODEL" restricted "<final-message-file>" || return 1
        log_info "[DRY RUN] Would review the plan with: $(harness_cmd_string) < <prompt>"
        HARNESS="$saved_harness"
        log_info "[DRY RUN] Then reconcile with $(harness_display_name) (${MODEL_PLAN:-harness default})"
        return 0
    fi

    local temp_prompt temp_output temp_err temp_final
    new_runner_temp temp_prompt
    new_runner_temp temp_output
    new_runner_temp temp_err
    new_runner_temp temp_final
    printf '%s' "$prompt" > "$temp_prompt"

    local start_ts
    start_ts=$(date +%s)

    # Swap the active harness for the single reviewer invocation
    local primary_harness="$HARNESS"
    HARNESS="$REVIEWER_HARNESS"
    local exit_code=0
    harness_exec "$REVIEWER_MODEL" restricted "$temp_prompt" "$temp_output" "$temp_err" "$temp_final" "${ITERATION_TIMEOUT:-900}" || exit_code=$?
    harness_parse_result "$temp_output" "$temp_err" "$temp_final"
    HARNESS="$primary_harness"

    log_harness_transcript "$temp_output" "$temp_err"
    release_runner_temp "$temp_prompt"
    release_runner_temp "$temp_output"
    release_runner_temp "$temp_err"
    release_runner_temp "$temp_final"

    local duration=$(( $(date +%s) - start_ts ))
    log_info "Review pass took ${duration}s, $(harness_usage_summary)"
    if declare -f log_iteration_summary > /dev/null 2>&1; then
        log_iteration_summary 0 "plan-review" "$REVIEWER_MODEL" "$duration" "$HARNESS_COST_USD" "reviewer pass" \
            "$REVIEWER_HARNESS" "$HARNESS_TOKENS_IN" "$HARNESS_TOKENS_OUT" "$HARNESS_USAGE_COMPLETE"
    fi

    if [[ -n "$HARNESS_ERRORS" ]]; then
        local err_line
        while IFS= read -r err_line; do
            log_error "$err_line"
        done < <(printf '%s\n' "$HARNESS_ERRORS" | head -3)
    fi
    if [[ $exit_code -eq 124 ]]; then
        log_error "Plan review timed out after ${ITERATION_TIMEOUT:-900}s"
        return 1
    fi
    if [[ $exit_code -ne 0 ]]; then
        log_error "Reviewer $(harness_display_name "$REVIEWER_HARNESS") exited with code $exit_code"
        return 1
    fi
    if [[ "$HARNESS_TEXT_OK" != "true" ]]; then
        log_error "Reviewer produced no final response"
        return 1
    fi

    local review_path="$PROJECT_DIR/$PLAN_REVIEW_FILE"
    local block
    block=$(_extract_plan_review_block "$HARNESS_TEXT")
    if [[ -z "$block" ]] || ! printf '%s\n' "$block" | grep -qE '^verdict:[[:space:]]*(APPROVE|REVISE)[[:space:]]*$'; then
        printf '%s\n' "$HARNESS_TEXT" > "$review_path"
        log_error "Reviewer output had no valid ===PLAN_REVIEW=== block with a verdict line; raw output saved to $PLAN_REVIEW_FILE"
        return 1
    fi

    local verdict finding_count
    verdict=$(printf '%s\n' "$block" | grep -E '^verdict:' | head -1 | sed 's/^verdict:[[:space:]]*//' | tr -d '[:space:]')
    finding_count=$(printf '%s\n' "$block" | grep -cE '^[[:space:]]*[0-9]+\.' || true)
    finding_count=${finding_count:-0}

    {
        echo "# Plan Review"
        echo ""
        echo "> Reviewer: $(harness_display_name "$REVIEWER_HARNESS") (${REVIEWER_MODEL:-harness default}), $(date '+%Y-%m-%d %H:%M'). Verdict: $verdict, $finding_count finding(s)."
        echo "> The primary planner ($(harness_display_name) ${MODEL_PLAN:-}) records a disposition for each finding under '## Dispositions' during reconciliation."
        echo ""
        printf '%s' "$block"
    } > "$review_path"
    log_success "Review written to $PLAN_REVIEW_FILE — verdict: $verdict, $finding_count finding(s)"

    if [[ "$verdict" == "APPROVE" ]] && [[ "$finding_count" -eq 0 ]]; then
        log_info "No findings — the plan stands as written"
        return 0
    fi

    _run_plan_reconciliation "$block"
}

# One planning iteration by the primary harness that addresses the review
_run_plan_reconciliation() {
    local review_block="$1"

    echo ""
    log_info "Reconciliation: $(harness_display_name) (${MODEL_PLAN:-harness default}) gives each finding a disposition and updates the plan"

    local template
    if ! template=$(_plan_review_template_path "PROMPT_plan.md"); then
        log_error "Prompt template not found: PROMPT_plan.md"
        return 1
    fi

    local instructions
    instructions="## Plan Review by a Second Model — RECONCILIATION PASS

A second model reviewed IMPLEMENTATION_PLAN.md; its findings are below. This iteration is a reconciliation pass, not a fresh plan:

1. For EVERY numbered finding decide: ACCEPT (change the plan accordingly) or REJECT (keep the plan; say in one line why the finding is wrong, already covered, or out of scope).
2. Append a \`## Dispositions\` section to \`$PLAN_REVIEW_FILE\` with one line per finding, in order: \`N. ACCEPTED — what changed\` or \`N. REJECTED — reason\`. Do not edit the review text above it.
3. Edit IMPLEMENTATION_PLAN.md for the accepted findings. Do not rewrite the plan from scratch; keep completed tasks and the existing format (checkbox tasks with [spec:] tags and (Done when:) checks).
4. A finding is not automatically right because it came from another model — reject it when the reviewer misread a spec or the planning rules.

$review_block"

    local prompt
    prompt=$(cat "$template")
    if [[ "$prompt" == *"{{PLAN_REVIEW}}"* ]]; then
        prompt=$(substitute_placeholder "$prompt" "{{PLAN_REVIEW}}" "$instructions")
    else
        # Custom project templates predate the placeholder — inject anyway
        prompt="$prompt"$'\n\n'"$instructions"
    fi

    # Fresh iteration state: no stale signals, a handoff note that says what
    # this pass is for
    clear_loop_signals "$STATE_DIR"
    printf '%s\n' "Reconciliation pass: a second model reviewed the plan. Address its findings (see $PLAN_REVIEW_FILE) — this is not a fresh planning iteration." \
        > "$PROJECT_DIR/$STATE_DIR/last_iteration_note"

    local temp_prompt
    new_runner_temp temp_prompt
    printf '%s' "$prompt" > "$temp_prompt"

    local saved_mode="$MODE"
    MODE="plan"
    export WALPH_MODE="plan" TOOL_MODE="plan"
    local exit_code=0
    run_shared_iteration 1 "$temp_prompt" "$MODEL_PLAN" "$STATE_DIR" || exit_code=$?
    MODE="$saved_mode"
    export WALPH_MODE="$MODE" TOOL_MODE="$MODE"
    clear_loop_signals "$STATE_DIR"
    release_runner_temp "$temp_prompt"

    if [[ $exit_code -ne 0 ]]; then
        log_error "Reconciliation pass failed (code $exit_code) — review $PLAN_REVIEW_FILE and IMPLEMENTATION_PLAN.md by hand"
        return 1
    fi
    if grep -q '^## Dispositions' "$PROJECT_DIR/$PLAN_REVIEW_FILE" 2>/dev/null; then
        log_success "Plan reconciled — dispositions recorded in $PLAN_REVIEW_FILE"
    else
        log_warn "Reconciliation ran but $PLAN_REVIEW_FILE has no '## Dispositions' section — check the plan by hand"
    fi
    return 0
}
