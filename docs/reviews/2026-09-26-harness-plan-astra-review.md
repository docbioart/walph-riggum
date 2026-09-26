# Codex gpt-6-astra review of the harness implementation plan (2026-09-26)

Produced by `codex exec -s read-only -m gpt-6-astra -c model_reasoning_effort=high` against this repository. Verdict: REVISE. All design-changing claims were verified locally before the plan was revised.

# 1. Factual corrections

**Verdict: REVISE.** The adapter approach is reasonable, but the plan inherits runner defects and makes several incorrect claims about output, permissions, and OpenCode behavior.

I read the requested repository files, checked the installed **Codex 0.157.0** and **OpenCode 1.18.30** help, and inspected relevant documentation and version-pinned OpenCode source. I did not modify files or run model-generation smoke tests.

1. **Codex stdin handling is broader than stated.** `codex exec -` is correct, but omitting the positional prompt also reads stdin. When a prompt argument and piped stdin are both supplied, this version appends stdin as additional context. The proposed explicit `-` is appropriate.

2. **Concatenating Codex `agent_message` items does not select the final answer.** Those items can include intermediate assistant messages. Use `--output-last-message` for the response consumed by Walph’s status parser; retain JSONL for diagnostics and usage. `--json` describes the event stream—it does not constrain the final response to JSON. [Codex non-interactive documentation](https://learn.chatgpt.com/docs/non-interactive-mode)

3. **The Codex item table is shorthand, not a uniform schema.** Do not assume every item has `.text`: command executions, file changes, and errors have different payloads. Nor should every `item.type == "error"` terminate a run: preserve warnings and determine failure from the process result and terminal events. Unknown events and optional usage fields should be tolerated.

4. **`-a never` is not an `exec` option in this version.** I verified that `codex exec -a never --help` fails with “unexpected argument.” Do not construct the alternative exactly as written. An exec-compatible explicit configuration is `-s danger-full-access -c approval_policy=never`. Sandbox policy and approval policy are separate controls. [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)

5. **`--ephemeral` prevents session persistence, not all disk writes.** It does not disable user configuration, instructions, caches, or agent filesystem operations. A newly created ephemeral run is unavailable for subsequent session-file-based `codex exec resume`. Walph’s restart-from-files model remains compatible. [Codex command reference](https://learn.chatgpt.com/docs/developer-commands?surface=cli)

6. **“Codex fast mode: none” is incorrect.** Codex supports fast mode through configuration, including `service_tier = "fast"` and the fast-mode feature setting, subject to model/account support. Keeping Walph’s existing `--fast` Claude-only is a valid scope decision; describe it as an unsupported adapter mapping, not an absent Codex capability. [Codex speed documentation](https://learn.chatgpt.com/docs/agent-configuration/speed)

7. **OpenCode `--auto` does not bypass explicit denials.** It automatically approves requests that would otherwise ask. Consequently, `access=full` cannot promise unrestricted execution. [OpenCode permissions](https://opencode.ai/docs/permissions/)

8. **OpenCode issue #26855 is fixed in the targeted source.** The fix merged in [PR #31389](https://github.com/anomalyco/opencode/pull/31389). In 1.18.30, local execution awaits the event consumer before returning. Keep truncated-stream tests, but do not characterize this historical issue as an established defect in 1.18.30.

9. **Ordinary local `opencode run` does not necessarily open a random-port server.** The targeted implementation dispatches requests through an in-process server. Its source also confirms stdin ingestion and that text events represent completed text parts, not exclusively the terminal answer. [OpenCode 1.18.30 `run.ts`](https://raw.githubusercontent.com/anomalyco/opencode/v1.18.30/packages/opencode/src/cli/cmd/run.ts)

10. **OpenCode usage is per step.** Taking tokens from only the last `step_finish` undercounts a run involving tools and multiple inference steps. Aggregate completed steps consistently with cost. Missing accounting must remain unknown, not become zero. [OpenCode 1.18.30 processor](https://raw.githubusercontent.com/anomalyco/opencode/v1.18.30/packages/opencode/src/session/processor.ts)

11. **Omitting OpenCode’s model delegates selection more broadly than to one config key.** Its documented fallback includes configuration, the last-used model, and internal priority. That is acceptable, but the resolved model may vary across machines. [OpenCode model selection](https://opencode.ai/docs/models/)

12. **“No bypass flag” is not a read-only guarantee for Claude.** Existing permission settings can authorize operations without prompting. The proposed abstraction should not label the current Jeeroy invocation strictly read-only merely because it omits `--dangerously-skip-permissions`. [Claude permission behavior](https://code.claude.com/docs/en/permissions)

# 2. Design flaws and risks

Ordered by severity.

### 1. Critical: diagnostic output can become orchestration control input

In [lib/runner.sh](/Users/artmorales/ralphwiggum/lib/runner.sh:113), `run_shared_iteration()` passes one combined string into error detection, status parsing, and the circuit breaker. The plan extends that approach by concatenating assistant messages, appending errors, and falling back to raw JSONL.

**Failure scenario:** an audit discusses “429,” “quota,” or `GOODBUNNY_STUCK`. The new broad patterns trigger an interactive rate-limit handler or stop the run. A transcript containing an example status block can also influence completion.

There is a factual repository mismatch here: `extract_status_block()` in [lib/status_parser.sh](/Users/artmorales/ralphwiggum/lib/status_parser.sh:23) extracts **all matching sed ranges**, not just the first block. I reproduced that two blocks produce multiple field values and prevent the existing exact completion comparison from succeeding.

**Fix:** distinguish final assistant text, diagnostic transcript, structured errors, and run outcome. Only final text should feed status/stuck parsing. Classify structured error messages rather than scanning ordinary prose for generic words. Keep malformed/raw output for diagnostics; never promote it to successful protocol output.

### 2. Critical: the proposed read-only contract is not enforced

**Failure scenario:** the reviewer invokes an allowed MCP/custom tool or a subagent that changes files or external state. OpenCode’s three denied tool categories do not cover all such capabilities, and agent-specific permissions can override global permissions. A Codex filesystem sandbox is also not a blanket denial of remote tool side effects. [OpenCode agent permission precedence](https://opencode.ai/docs/permissions/), [Codex sandbox scope](https://learn.chatgpt.com/docs/sandboxing)

There is a separate configuration bug: setting a new `OPENCODE_CONFIG_CONTENT` value **replaces the inherited environment value**. OpenCode’s merging of configuration layers does not merge two versions of the same environment variable. A user’s inline provider/model settings would disappear.

**Fix:** define what `readonly` guarantees. For this review feature, restrict available tools to the reading capabilities needed, disable mutation-capable integrations/delegation, and verify effective agent permissions. Preserve existing inline configuration when adding restrictions. If strict enforcement cannot be provided, state the weaker guarantee explicitly instead of advertising equivalent read-only behavior across harnesses.

### 3. High: the runner’s exit handling cannot remain unchanged

`run_shared_iteration()` executes bare `wait "$claude_pid"` under `set -e`, then tries to capture `$?`. A nonzero exit can terminate the script before parsing or logging. Timeout cleanup contains the same problem. Bare nonzero returns elsewhere in the call chain have similar consequences.

Conversely, if execution reaches the completion branch, `check_completion()` can cause `return 0` without requiring a successful process result.

**Failure scenario:** authentication failure exits before useful diagnostics; or a failed/interrupted run with a completion-looking payload is reported as successful.

**Fix:** explicitly capture expected nonzero statuses at each relevant boundary. Define completion as successful execution **and** valid terminal output **and** existing ground-truth checks. Preserve timeout, failure, interruption, and incomplete outcomes separately. Do not “fix” this merely by wrapping the entire loop in a conditional: Bash’s `errexit` suppression inside called functions makes that a broader behavioral change.

### 4. High: timeout cleanup does not establish process ownership

The installed Codex launcher is a Node wrapper that spawns the native executable and forwards ordinary signals. Killing its PID is not proof that every descendant has exited; `SIGKILL` cannot be forwarded.

**Failure scenario:** a surviving shell or MCP process continues editing while the next Walph iteration starts. `kill "$pid"; pkill -P "$pid"` can miss children that have already been reparented. An unverified negative PGID can instead kill Walph’s own process group.

The existing cleanup also needs attention: `temp_prompt=$(make_runner_temp)` updates `RUNNER_TEMP_FILES` inside a subshell, so the parent does not retain that registration. The signal trap removes files but does not explicitly terminate the active process tree or exit.

**Fix:** establish and record an owned process group/session at launch, terminate it with a bounded TERM/KILL sequence, and reap the leader. Test the chosen mechanism on macOS and Linux. Repair temporary-file registration and signal handling in the same runner change. Do not assume a process group captures independently detached daemons.

### 5. High: configuration resolution is underspecified and already contains relevant bugs

In [lib/config.sh](/Users/artmorales/ralphwiggum/lib/config.sh:33), `load_config()` preserves surrounding quotes. `load_goodbunny_config()` duplicates that behavior. I reproduced that the documented `MODEL_PLAN="opus"` becomes a value containing literal quote characters.

**Failure scenario:** the proposed `opus|sonnet|haiku` guard misses `"opus"` and sends an invalid model to Codex. New quoted `HARNESS` values would also fail validation.

Additionally, current CLI parsing and config loading share variables; merely assigning `HARNESS` during argument parsing would allow the config loader to overwrite it. Jeeroy has neither the proposed config loading path nor a harness-aware replacement for its unconditional `MODEL="opus"`.

**Fix:** normalize supported config quoting without sourcing arbitrary shell code; retain CLI overrides separately; load raw configuration; resolve harness; then resolve models. Define Jeeroy’s config source and `TOOL_ENV_PREFIX` initialization explicitly. Limit alias migration to inherited legacy values—do not silently substitute an explicitly requested model. Scope reviewer configuration separately from the primary invocation.

### 6. High: the review/reconciliation workflow can silently fail to review the plan

Several repository details make the current specification insufficient:

- Existing projects preferentially use `.walph/PROMPT_plan.md`; those copies will not contain the new `{{PLAN_REVIEW}}` placeholder.
- `run_main_loop()` returns zero on maximum iterations and user-requested exit, even when `LOOP_COMPLETED=false`.
- `jeeroy.sh:run_lfg_pipeline()` checks command success and whether the plan contains checkboxes. It does not establish that planning or review completed.
- `PROMPT_plan.md` does not currently require committing the plan or review report.
- Skipping reconciliation after APPROVE leaves no reconciliation step to perform the promised commit.
- Reusing planning state can leave completion signals or “planning complete” handoff notes that are inappropriate for reconciliation.

**Failure scenario:** Jeeroy starts building an existing task list after planning stops before the requested review; or reconciliation receives an old custom template that never includes the findings.

**Fix:** specify outcomes for valid approval, completed reconciliation, malformed review, timeout, reviewer failure, and incomplete planning. When review was requested, incomplete review/reconciliation must block automatic building. Inject the review instructions independently of whether a custom template contains the placeholder. Keep review state separate from ordinary loop completion. Make artifact persistence and commit behavior explicit.

### 7. High: installation and Jeeroy dependencies are missed

[install.sh](/Users/artmorales/ralphwiggum/install.sh:20) still exits unless `claude` is installed.

**Failure scenario:** a Codex-only user cannot install the advertised multi-harness tool.

Also, `jeeroy.sh:validate_environment()` does **not** require jq today. Converting its analysis/generation paths to mandatory JSON parsing introduces a new dependency that the plan does not add there.

**Fix:** update installation requirements and Jeeroy validation. Resolve the selected harness before checking dependencies. Validate both primary and reviewer harnesses when both will run.

### 8. High: unrestricted extra arguments can invalidate the adapter’s guarantees

Intentional word splitting is not shell argument parsing. Quotes inside `HARNESS_EXTRA_ARGS` do not preserve a multiword argument, and unquoted expansion also performs pathname expansion.

**Failure scenario:** quoted configuration values split incorrectly; wildcard arguments expand into repository filenames; or extra options override output format, directory, model, sandbox, or session behavior. Primary Codex arguments can also accidentally reach an OpenCode reviewer.

**Fix:** preferably omit generic passthrough initially and expose the two demonstrated options explicitly. Otherwise use a defined argument-array encoding, forbid adapter-owned options, and scope extras per invocation/harness. Never use `eval` to recover quoting.

### 9. Medium: the review rubric contradicts the existing planning rubric

[templates/PROMPT_plan.md](/Users/artmorales/ralphwiggum/templates/PROMPT_plan.md) explicitly permits non-spec-derived tasks, such as scaffolding, to omit `[spec:]`.

**Failure scenario:** the reviewer generates mandatory findings against plans that correctly follow the primary prompt. It may also demand frontend/backend or UI tasks for projects where those conditions do not apply.

**Fix:** preserve the existing exceptions and conditional requirements. Supply the effective project `PRINCIPLES.md`, not merely assumptions about the distributed template. Require dispositions for findings; do not mechanically accept every reviewer recommendation.

### 10. Medium: metrics and diagnostics need a defined contract

The proposed globals omit whether accounting is complete and whether a usable terminal response was obtained. They also risk retaining values from the previous invocation unless reset.

**Failure scenario:** a failed second run inherits the first run’s cost or final text. An OpenCode partial stream is logged as a complete low-cost run. Different input-token conventions become misleadingly comparable.

**Fix:** reset every result field on entry; distinguish unknown from zero and partial from complete; document token accounting. Preserve raw usage fields in logs. Update `log_iteration_summary()` in [lib/logging.sh](/Users/artmorales/ralphwiggum/lib/logging.sh:131), where it actually resides. Treat requested and resolved models separately when a harness chooses its own default.

### 11. Medium: proposed verification misses the failure paths most likely to break

Parser fixtures, dry runs, and two successful live iterations cannot detect most issues above.

**Fix:** add deterministic fake-CLI integration tests covering nonzero exits, terminal error events, timeout descendants, interrupts, misleading prose, multiple status blocks, missing final output, quoted config, CLI precedence, reviewer failure, existing custom templates, and Jeeroy handoff. Run these under **actual Bash 3.2** as well as a modern Bash.

`check_chrome_mcp()` should also remain an advisory heuristic. Finding a name in some other harness’s config is not evidence that the selected harness can use that server.

# 3. Answers to the open questions

1. **Codex facts and ephemeral/resume:** The proposed main exec command uses valid installed flags. Correct stdin, final-message, fast-mode, and approval-option statements as above. Treat the table as a supported subset of events, not a complete schema. `--ephemeral` fits fresh iterations, but rules out resuming that newly created run from persisted session files. Walph resume instructions should continue to mean restarting from repository state.

2. **Bypass versus `danger-full-access` plus `never`:** The bypass flag is a reasonable choice given the stated user decision to preserve unrestricted autonomous execution. Both configurations express unsandboxed execution without human approval, but do not promise identical treatment of every independent policy mechanism. In particular, hook trust has its own separate bypass flag. Use the supported exec syntax; do not add `-a` after `exec`. Neither choice overrides an enclosing OS/container restriction.

3. **Child processes on timeout:** Yes, assume descendants can survive unless lifecycle management proves otherwise. Normal shutdown may clean them up; that is not a forced-termination guarantee. Correct the OpenCode random-port premise, but retain process-tree tests for both harnesses. Use an owned group/session, not parent-first `pkill -P`.

4. **Concatenating messages:** No, not for control parsing. Use Codex’s final-message file. For OpenCode, preserve message/part identity and select the terminal assistant response rather than treating every text part as final. Then require an unambiguous, complete status block. The current parser collects multiple ranges.

5. **Dollar-cost estimates:** Agree with the plan: do not add a price table. Keep Codex cost unknown and log tokens. A static table would introduce maintenance and accounting assumptions unrelated to the feature.

6. **`-C`, Git checks, and `AGENTS.md`:** `-C` intentionally affects instruction discovery. Codex discovers global instructions and project instructions along the root-to-working-directory path; without a discovered project root it checks the current directory. `--skip-git-repo-check` permits execution outside Git; it does not disable instructions. Walph currently asks the model to read `AGENTS.md` rather than embedding its contents, so there is possible redundant reading, not literal duplicate template injection. [Codex instruction discovery](https://learn.chatgpt.com/docs/agent-configuration/agents-md)

7. **Single reconciliation versus approval loop:** Keep one review and one reconciliation. An approval loop adds expense, disagreement cycles, and more state without being necessary for “two models have input.” However, call the result “reconciled,” not “reviewer approved,” unless it was actually re-reviewed. Specify validation, finding dispositions, failure propagation, and the existing-template behavior described above.

8. **Bash 3.2 pitfalls:** The largest immediate defect is empty-array expansion under `set -u`. I reproduced:

   ```bash
   /bin/bash -uc 'a=(); printf "%s\n" "${a[@]}"'
   # a[@]: unbound variable
   ```

   Therefore `env "${HARNESS_ENV[@]}" ...` fails on ordinary runs where no environment additions exist. Use a tested guarded expansion or one nonempty execution array beginning with `env`. Also avoid pipeline/subshell assignments when functions must populate parent globals, reset arrays between invocations, and keep logs off stdout in value-returning helpers. `lib/status_parser.sh:parse_status()` already contains `local -n`; it appears unused by the current loop, so do not start using it. ShellCheck alone does not establish Bash 3.2 compatibility.

9. **Good Bunny and Jeeroy:** Several concrete gaps remain.

   **Good Bunny:** `--skip-git-repo-check` solves Codex’s startup restriction only. `_working_tree_sig()` cannot detect meaningful non-Git changes through Git status/diff operations, while audit/analyze templates unconditionally request commits. Preserve non-Git auditing with suitable progress tracking and conditional commit instructions. Exclude orchestration logs/state from progress detection explicitly: `ensure_goodbunny_dirs()` only adds ignore entries when `.gitignore` already exists, and `_working_tree_sig()` does not comprehensively exclude logs or tracked state diffs. `GOODBUNNY_STUCK` is recognized today, but its stop behavior relies on a nonzero return from `update_circuit_breaker()`; make that explicit when fixing exit handling.

   **Jeeroy:** add jq validation, harness-aware model resolution, consistent target-directory execution, and clean final-text parsing before `extract_analysis_block()` or `extract_and_write_specs()`. Reject failed/truncated generations before its permissive unterminated-spec fallback writes partial files. Keep large documents on stdin and the interactive context-file approach. Stdin avoids shell argument-size limits, but model context, request-size, and memory limits still apply; the available evidence does not justify a universal Codex/OpenCode stdin maximum.

# 4. Simplifications

- **Delete the runner’s no-jq text fallback.** Walph and Good Bunny already require jq; add that requirement explicitly to Jeeroy.
- **Cut unrestricted `HARNESS_EXTRA_ARGS` from the first implementation.** Explicit reasoning/variant settings cover the demonstrated need.
- **Parse each JSONL file in one jq process**, using raw-line input and `fromjson?`, rather than launching jq once per line. Track malformed input separately instead of silently treating every parse failure as harmless.
- **Pass output file paths to the parser.** This avoids repeatedly copying potentially large event streams into shell variables.
- **Reuse one bounded process-execution helper** across the loop, Jeeroy’s noninteractive calls, and plan review. Their result handling can differ without duplicating timeout and cleanup logic.
- **Keep one review plus one reconciliation.** No price table, automatic approval loop, or session-resume abstraction is needed.
- **Keep `PLAN_REVIEW.md` human-readable without automatic committing initially.** Visibility does not require an additional commit policy.

# 5. Verdict: REVISE

Before implementation, minimally revise the plan to:

1. Separate final response, diagnostics, structured errors, and execution outcome.
2. Define enforceable read-only behavior and preserve inherited OpenCode configuration.
3. Repair exit-status handling, timeout ownership, signal cleanup, and Bash 3.2 empty-array handling.
4. Specify configuration precedence, quote normalization, and independent primary/reviewer settings.
5. Add the missed installer and Jeeroy dependency/model changes.
6. Define review validation and failure propagation, including existing custom templates and Jeeroy’s automatic build gate.
7. Add fake-CLI failure-path tests under Bash 3.2 and correct the version-specific factual claims above.

The harness boundary is worth keeping. The current execution and review contracts need revision before building on it.