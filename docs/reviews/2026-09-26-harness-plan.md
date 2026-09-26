# Harness feature — implementation plan v2 (2026-09-26)

Reviewed by Codex gpt-6-astra before implementation; see [2026-09-26-harness-plan-astra-review.md](2026-09-26-harness-plan-astra-review.md).

# Implementation Plan v2 — multi-harness (--harness claude|codex|opencode) + second-model plan review
Revised after Codex gpt-6-astra review (astra-review.md). All Astra factual claims that change the design were verified locally.

## A. Harness layer — lib/harness.sh (new; only file that knows CLI syntax; bash 3.2 safe)
- resolve_harness: CLI override var > ${TOOL}_HARNESS env > config HARNESS > claude. Validate. CLI override stored in HARNESS_OVERRIDE and applied AFTER config load (same pattern as MODEL_OVERRIDE).
- harness_check_installed (+ per-harness install hint). jq required by all three tools (add to Jeeroy).
- harness_model_default <phase>: claude opus/sonnet/opus/opus/sonnet/opus; codex gpt-6-astra (plan, verify, audit, analyze, review), gpt-5.6-sol (build, fix); opencode "" (harness default). Jeeroy analysis/generation phase = "plan" defaults.
- harness_exec <model> <access> <prompt_file> <out_file> <err_file> <final_file> <timeout>: the single bounded-execution helper used by runner, Jeeroy, and plan review.
  * Launches under `set -m` so the child gets its own process group (verified on bash 3.2); on timeout: TERM the group, wait 2s, KILL the group, reap leader; exit code 124. INT/TERM trap does the same then exits.
  * `wait "$pid" || ec=$?` guard (bare wait under set -e kills the script today — verified).
  * Empty-array expansion guarded `${arr[@]+"${arr[@]}"}` everywhere.
  * Commands:
    - claude full:  claude -p --dangerously-skip-permissions [--model M] --output-format json [--settings fastMode] ; final text = .result
    - claude restricted: same minus bypass flag (respects user's own permission settings — documented as weaker than read-only)
    - codex full: codex exec --json --ephemeral --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox -C "$PROJECT_DIR" [-m M] [-c model_reasoning_effort=E] -o "$final_file" -
    - codex restricted: same with -s read-only instead of bypass
    - opencode full: opencode run --format json --auto --dir "$PROJECT_DIR" [-m M] [--variant E]   (prompt on stdin)
    - opencode restricted: same minus --auto; OPENCODE_CONFIG_CONTENT = jq-merge of any inherited value with {"permission":{"edit":"deny","bash":"deny","webfetch":"deny","task":"deny"}}
  * Access levels are named full|restricted (not "readonly"); README states exactly what each harness enforces.
- harness_parse_result <harness> <out_file> <err_file> <final_file>: resets then sets HARNESS_TEXT (final assistant response only), HARNESS_TEXT_OK (true/false), HARNESS_COST_USD ("" = unknown), HARNESS_TOKENS_IN/OUT ("" = unknown), HARNESS_USAGE_COMPLETE, HARNESS_ERRORS (structured error messages, newline-separated). One jq process per file using `fromjson?`; malformed lines counted, not fatal.
  * claude: .result, .total_cost_usd, .is_error/.subtype for errors
  * codex: final text from -o file; usage from last turn.completed; errors from turn.failed/error events (item.type=="error" items are warnings → diagnostics only)
  * opencode: final text = text parts of the LAST messageID that has any text part, joined; cost/tokens summed over all step_finish; usage complete only if last event has reason=="stop"; errors from error events (.error.name + .error.data.message)
- REASONING_EFFORT config/env (WALPH_REASONING_EFFORT etc.): codex -c model_reasoning_effort, opencode --variant, claude ignored. No generic extra-args passthrough (dropped per review).
- --fast: claude only; warn+ignore elsewhere (docs note codex service_tier config as the manual alternative).

## B. Runner (lib/runner.sh) and parsers
- run_shared_iteration uses harness_exec + harness_parse_result. Delete no-jq text fallback.
- Separate streams: HARNESS_TEXT → status block / stuck signal / completion; HARNESS_ERRORS + stderr → rate-limit & API-error classification; raw stdout → log file only.
- Completion requires: exit code 0 AND HARNESS_TEXT_OK AND status HIGH+EXIT_SIGNAL AND ground-truth checkboxes. Timeout / nonzero / no-final-text are logged as distinct outcomes and never count as completion.
- status_parser: extract_status_block returns only the LAST block (awk). check_rate_limit/check_api_error take the structured error text + stderr, not prose; keep existing claude text patterns for stderr. Add codex/opencode patterns (turn.failed, rate limit, 429, APIError, quota) applied only to that error channel.
- Fix make_runner_temp subshell registration (caller appends to RUNNER_TEMP_FILES).
- Circuit breaker unchanged except GOODBUNNY_STUCK/RALPH_STUCK checked against HARNESS_TEXT.
- log_iteration_summary (lib/logging.sh): add harness, tokens_in, tokens_out, usage_complete columns; cost blank when unknown. Log line prints cost when known else tokens.
- Dry run prints harness + exact argv via printf %q.

## C. Config (lib/config.sh, goodbunny.sh, jeeroy.sh)
- Strip matching surrounding quotes from config values in both loaders (bug verified: MODEL_PLAN="opus" keeps quotes).
- Order: load raw config → resolve harness (with CLI override) → resolve models with harness defaults → apply --model override.
- Legacy alias guard: if harness != claude and a model value came from config/default and is opus|sonnet|haiku → warn and use harness default. If it came from --model → error out.
- New keys: HARNESS, REASONING_EFFORT, PLAN_REVIEWER (harness[:model]). Env: WALPH_HARNESS, GOODBUNNY_HARNESS, JEEROY_HARNESS, JEEROY_MODEL, WALPH_REASONING_EFFORT, GOODBUNNY_REASONING_EFFORT, WALPH_PLAN_REVIEWER.
- Jeeroy: MODEL default becomes harness_model_default plan (was hardcoded opus); validate_environment requires jq and the resolved harness binary.
- Generated config templates (init, setup, goodbunny first run, config.sh write_default_config) get commented HARNESS/REASONING_EFFORT/PLAN_REVIEWER lines and per-harness model examples; stale full model-name examples replaced.

## D. CLI surface
- --harness on walph plan/build/verify/review-plan, goodbunny audit/fix/analyze, jeeroy. RESUME_COMMAND includes --harness when non-default.
- jeeroy --lfg passes --harness (and --reviewer if given) to walph plan/build only.
- install.sh: require jq + at least one of claude/codex/opencode (was: claude mandatory). uninstall unchanged.
- check_chrome_mcp: checks only the SELECTED harness's config (codex ~/.codex/config.toml + ./.codex/config.toml; opencode ~/.config/opencode/opencode.json + ./opencode.json; claude as today); advisory wording.
- Help/how-to screens updated. templates/PRINCIPLES.md, PROMPT_build.md, PROMPT_verify.md: chrome-devtools tool names without the Claude-specific mcp__ prefix.

## E. Second-model plan review (opt-in, no default)
- templates/PROMPT_plan_review.md (copied to .walph/ by init/setup). Rubric mirrors PROMPT_plan.md exactly: scaffolding tasks may omit [spec:]; FE/BE contract and UI-test tasks required only when the project has those; uses effective {{PRINCIPLES}}. Output: ===PLAN_REVIEW=== verdict: APPROVE|REVISE, numbered findings (each: severity, what, which spec/task, suggested change) ===PLAN_REVIEW_END===.
- `walph review-plan --reviewer <harness>[:<model>]`: one harness_exec with access=restricted using the reviewer harness/model; validate the block (markers + verdict) else log error, save raw output to PLAN_REVIEW.md, exit 1. Save formatted review to PLAN_REVIEW.md (project root, not auto-committed). Then one reconciliation pass with the PRIMARY harness/plan model: PROMPT_plan.md with a review block appended (injected whether or not a custom .walph/PROMPT_plan.md has a {{PLAN_REVIEW}} placeholder) instructing: give each finding a disposition (accepted → plan changed / rejected → one-line reason), write dispositions into PLAN_REVIEW.md under "## Dispositions", update IMPLEMENTATION_PLAN.md. Runs with fresh iteration state (completion signal cleared, handoff note set to "reconciliation pass"). Result is reported as "reconciled", never "approved". APPROVE with zero findings → skip reconciliation, still write PLAN_REVIEW.md.
- `walph plan --reviewer X` chains into review-plan only if LOOP_COMPLETED=true; otherwise warns and exits 1. jeeroy --lfg: if --reviewer was requested and review/reconciliation did not complete, do NOT build.
- Reviewer harness/model resolved independently of the primary (own install check, own model default for phase "review").

## F. Tests (tests/, plain bash, run under /bin/bash 3.2; also newer bash if present)
- tests/fixtures/: captured codex/opencode JSONL and claude JSON; truncated and multi-message variants.
- tests/harness_parse_test.sh: parser expectations per harness (final text selection, unknown vs zero cost, partial usage, malformed lines).
- tests/fake-bins/{claude,codex,opencode}: scenario-driven fakes (FAKE_SCENARIO=ok|nonzero|error_event|hang_with_child|two_status_blocks|truncated|no_final). tests/runner_integration_test.sh drives walph build/plan with PATH prepended, asserting: nonzero exit doesn't kill the loop, timeout kills the child too, misleading prose doesn't trip rate-limit, last status block wins, no completion without final text, quoted config values work, --harness/--model precedence, review-plan failure blocks jeeroy build.
- shellcheck on everything; --dry-run matrix; live: 2-iteration build on a tiny spec with codex and with opencode; one live review-plan with codex:gpt-6-astra.

## G. Docs
README (Harnesses section, requirements, config/env tables, plan review), QUICKSTART, help screens. Save astra-review.md into docs/reviews/ for provenance? (ask user)

## Explicitly out of scope (pre-existing, noted)
- Good Bunny on non-git directories: change detection can't work without git; --skip-git-repo-check only unblocks codex startup. Documented limitation.
- Price table for codex dollar cost. Approval loop for plan review. Session resume across harnesses.
