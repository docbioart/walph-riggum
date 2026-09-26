# Walph Riggum

An autonomous coding loop that runs a coding agent from the *outside* to build software projects with clean context every iteration. It drives **Claude Code** by default and can run the same loop on **OpenAI Codex CLI** or **OpenCode** with `--harness`.

Comes with **[Jeeroy Lenkins](#jeeroy-lenkins---document-to-spec-converter)**, a companion tool that turns any pile of docs (Word, PDF, PowerPoint, markdown, etc.) into Walph-ready specs and optionally kicks off the entire pipeline with a single `--lfg` flag. Docs in, working code out.

And **[Good Bunny](#good-bunny---autonomous-code-quality-reviewer)**, a code quality reviewer that audits any project for issues across 9 categories, fixes them autonomously, and can generate a comprehensive codebase documentation report. No setup required.

> "Me fail English? That's unpossible!" - Walph Riggum

## Why Walph?

### The Problem with Long Sessions

When you use Claude Code interactively for a large project, the context window fills up. Claude starts forgetting earlier decisions, repeating mistakes, or losing track of what's been done. The conversation becomes unwieldy.

### The Solution: Fresh Context, Persistent Memory

Walph takes a different approach:

- **Each iteration starts fresh** - Claude gets a clean context window every time
- **Memory lives in files** - `IMPLEMENTATION_PLAN.md` tracks progress, git commits preserve history
- **One task at a time** - Claude focuses on a single task, completes it, commits, exits
- **The loop continues** - Walph restarts Claude with the updated state

This is how humans work on large projects: do one thing, save your work, take a break, come back with fresh eyes.

## How It's Different

| Approach                     | Context              | Memory          | Docs-to-Code                | Best For                    |
|------------------------------|----------------------|-----------------|-----------------------------|-----------------------------|
| **Interactive Claude Code**  | Accumulates          | In conversation | Manual                      | Small tasks, exploration    |
| **Claude Code plugins**      | Accumulates          | In conversation | Manual                      | Extending functionality     |
| **Walph Riggum**             | Fresh each iteration | Files + Git     | One-shot via Jeeroy `--lfg` | Large projects, autonomy    |
| **Good Bunny**               | Fresh each iteration | REVIEW_FINDINGS | N/A                         | Code quality, codebase docs |

Walph is not a Claude Code plugin. It's an external orchestrator that *runs* an agent CLI repeatedly, giving each invocation exactly what it needs and nothing more. The CLI is pluggable: Claude Code by default, Codex or OpenCode with `--harness` (see [Harnesses](#harnesses)).

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                         WALPH LOOP                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   ┌─────────┐     ┌──────────────┐     ┌─────────┐              │
│   │  specs/ │────>│  walph plan  │────>│  PLAN   │              │
│   │  (you)  │     │   (Opus)     │     │  .md    │              │
│   └─────────┘     └──────────────┘     └────┬────┘              │
│                                             │                   │
│                                             v                   │
│   ┌─────────┐     ┌──────────────┐     ┌─────────┐              │
│   │  Code   │<────│ walph build  │<────│  PLAN   │              │
│   │  + Git  │     │  (Sonnet)    │     │  .md    │              │
│   └─────────┘     └──────┬───────┘     └─────────┘              │
│                          │                                      │
│                          │ loop until done                      │
│                          │ or stuck                             │
│                          v                                      │
│                   ┌──────────────┐                              │
│                   │   Complete   │                              │
│                   └──────────────┘                              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

1. **You write specs** in `specs/*.md` - describe what you want built
2. **Plan phase** (Opus) - Claude reads specs and generates a task list in `IMPLEMENTATION_PLAN.md`. Each task cites its source spec (`[spec: feature.md]`) and names its verification (`(Done when: ...)`). Walph lints your specs for missing sections before planning.
3. **Build phase** (Sonnet) - Claude picks ONE task, re-reads the spec it came from, implements it, runs tests, marks it done, commits
4. **Verify phase** (Opus) - After the build completes, Claude exercises every acceptance criterion in your specs (tests, curl, real browser for UI), checks off the ones that pass, and files fix tasks for the ones that fail. The specs — not the plan — decide when the project is done. (Skip with `WALPH_SKIP_VERIFY=true`.)
5. **Loop** - Walph restarts Claude with the updated plan, repeating until all tasks are complete. A short handoff note from the previous iteration is injected into each fresh context, and Claude's "I'm done" signal is only trusted when the checkboxes on disk agree.

Each build iteration is independent. Claude reads the current state from files, does one task, saves its work. No context accumulation, no memory degradation.

## Features

- **Dual-model strategy**: Opus for planning and verification (smarter), Sonnet for building (faster); on Codex, gpt-6-astra and gpt-5.6-sol
- **Pluggable harness**: run the same loop on Claude Code (default), Codex CLI, or OpenCode with `--harness`
- **Second-model plan review**: `walph plan --reviewer codex:gpt-6-astra` has a different model critique the plan, then the planner reconciles its findings (opt-in, no default)
- **Spec-driven end to end**: specs are linted before planning, re-read during building, and their acceptance criteria are exercised during verification
- **Circuit breaker**: Auto-stops if Claude gets stuck (no changes, same error, no commits)
- **Ground-truth completion**: the loop only ends when the checkboxes on disk agree, not just when Claude says so
- **Iteration memory**: each fresh context receives a short note about what the previous iteration did (and warnings when the loop is losing traction)
- **Cost tracking**: per-iteration duration and API cost logged to a session summary CSV (requires `jq`)
- **Git-native**: Every completed task becomes a commit - easy to review, revert, or continue
- **Stack templates**: Quick setup for Node.js, Python, Swift, Kotlin, Capacitor, and more
- **Customizable prompts**: Modify `.walph/PROMPT_*.md` (and the shared rules in `.walph/PRINCIPLES.md`) to change Claude's behavior
- **Existing project support**: `walph setup` adds Walph to any project

## Requirements

- **An agent CLI** (one required) - [Claude Code](https://docs.claude.com/claude-code) (`claude`, the default), [Codex CLI](https://developers.openai.com/codex) (`codex`), or [OpenCode](https://opencode.ai) (`opencode`)
- **Git** (required) - For version control and commits
- **jq** (required) - Parses the agents' JSON output and tracks cost
- **chrome-devtools MCP** (recommended) - For UI testing, configured in whichever agent CLI you use. Without it, UI testing must be done manually.

> **Note:** Walph will warn if chrome-devtools MCP is not configured for the selected harness but will continue. UI tasks will need manual verification.

## Quick Start

### New Project

```bash
# Clone Walph
git clone https://github.com/docbioart/walph-riggum.git
cd walph-riggum

# Create a new project
./walph.sh init my-api --template api

# Enter project and write your spec
cd my-api
# Edit specs/TEMPLATE.md with what you want built

# Generate the plan
../walph.sh plan

# Review IMPLEMENTATION_PLAN.md, then build
../walph.sh build --max-iterations 20
```

### Existing Project

```bash
cd your-existing-project

# Add Walph (auto-detects your stack)
/path/to/walph.sh setup

# Edit AGENTS.md with your build/test commands
# Write specs in specs/

# Plan and build
/path/to/walph.sh plan
/path/to/walph.sh build
```

## Project Structure

```
your-project/
├── .walph/
│   ├── config              # Settings (models, thresholds)
│   ├── PROMPT_plan.md      # Planning prompt (customizable)
│   ├── PROMPT_build.md     # Building prompt (customizable)
│   ├── PROMPT_verify.md    # Verification prompt (customizable)
│   ├── PRINCIPLES.md       # Shared engineering rules injected into all prompts
│   ├── logs/               # Session logs + per-iteration cost summary CSV
│   └── state/              # Circuit breaker state + iteration handoff note
├── specs/
│   └── *.md                # Your requirements (Walph reads all .md files)
├── AGENTS.md               # Build/test/lint commands
└── IMPLEMENTATION_PLAN.md  # Task list with checkboxes
```

## Commands

```bash
walph                           # Show comprehensive how-to
walph init <name> [options]     # Create new project
walph setup [options]           # Add Walph to existing project
walph plan                      # Generate tasks from specs (lints specs first)
walph build                     # Implement tasks (the main loop)
walph verify                    # Check implementation against spec acceptance
                                #   criteria (auto-runs after a completed build)
walph review-plan --reviewer X  # Second model reviews the plan, planner reconciles
walph status                    # Show progress
walph reset                     # Clear stuck state
```

### Options

```
--harness <name>      Agent CLI to run: claude (default), codex, opencode
--model <name>        Override model for this run (must fit the harness)
--reviewer <spec>     Second-model plan review: <harness>[:<model>], e.g. codex:gpt-6-astra
--max-iterations N    Limit iterations (default: 50)
--monitor             Tmux split with logs + git status
--dry-run             Show what would run (prints the exact agent command)
```

## Harnesses

The loop is the same on every harness: prompt on stdin, one non-interactive run with permissions bypassed, JSON events parsed for the final response and usage, then the next fresh-context iteration.

```bash
walph build                              # Claude Code (default)
walph build --harness codex              # Codex CLI
walph build --harness opencode           # OpenCode
export WALPH_HARNESS=codex               # or set HARNESS=codex in .walph/config
```

| | Claude Code | Codex CLI | OpenCode |
|---|---|---|---|
| Command | `claude -p` | `codex exec -` | `opencode run` |
| Default models (plan / build / verify) | opus / sonnet / opus | gpt-6-astra / gpt-5.6-sol / gpt-6-astra | your `opencode.json` model |
| Model override format | `--model opus` | `--model gpt-5.6-terra` | `--model provider/model` |
| Full access (plan, build, verify, fix) | `--dangerously-skip-permissions` | `--dangerously-bypass-approvals-and-sandbox` | `--auto` |
| Restricted access (Jeeroy analysis, plan review) | no bypass flag: your own Claude permission settings apply | `--sandbox read-only` | `--auto` withheld plus `edit`/`bash`/`webfetch`/`task` denied via inline config |
| Cost in the summary CSV | dollars | tokens only (Codex reports no price) | dollars when the provider prices the model, else 0 |
| Reasoning effort (`REASONING_EFFORT`) | ignored | `model_reasoning_effort` | `--variant` |
| `--fast` | supported | ignored with a warning | ignored with a warning |

Model names are validated against the harness: a Claude alias like `opus` inherited from a config file on another harness falls back to that harness's default with a warning, while passing one explicitly with `--model` is an error.

**What "restricted" means.** It is best effort, not a guarantee. Codex's read-only sandbox blocks file writes and most side effects. OpenCode's deny rules cover its built-in tools but not custom MCP servers a user has configured. Claude Code in restricted mode simply runs without the bypass flag, so whatever your permission settings already allow is allowed. Restricted runs are used where the agent only needs to read and answer.

## Second-Model Plan Review

A plan written by one model can be checked by another before anything is built. There is no default reviewer; it runs only when asked.

```bash
walph plan --reviewer codex:gpt-6-astra      # plan with the primary harness, then review
walph review-plan --reviewer claude:opus     # review an existing plan
export WALPH_PLAN_REVIEWER=codex             # or PLAN_REVIEWER=codex in .walph/config
```

1. **Review pass** - the reviewer harness/model reads the specs and the plan with restricted access and writes a verdict plus numbered findings to `PLAN_REVIEW.md`
2. **Reconciliation pass** - the primary planner re-reads the plan with the findings injected, records a disposition for each one under `## Dispositions` in `PLAN_REVIEW.md` (accepted with what changed, or rejected with why), and edits `IMPLEMENTATION_PLAN.md` accordingly

A malformed or failed review exits non-zero, and Jeeroy's `--lfg` will not start a build when a requested review did not complete. The result is reported as "reconciled", not "approved": the reviewer is not asked again.

## Writing Good Specs

The quality of your specs determines the quality of the output.

**Good spec:**
```markdown
## POST /users
- Request: `{ "email": "user@example.com", "name": "Jane" }`
- Response: `{ "id": 1, "email": "...", "name": "..." }`
- Returns 400 if email is invalid or already exists
- Returns 201 on success

## Files to create
- `src/routes/users.js` - Route handler
- `src/services/user-service.js` - Business logic
- `tests/users.test.js` - Integration tests
```

**Bad spec:**
```markdown
Handle user management with proper validation.
```

Include: specific endpoints, input/output examples, error cases, files to create.

## Configuration

### .walph/config

```bash
HARNESS=claude                 # claude | codex | opencode
MAX_ITERATIONS=50
MODEL_PLAN="opus"              # defaults depend on the harness; values may be quoted or bare
MODEL_BUILD="sonnet"
MODEL_VERIFY="opus"
REASONING_EFFORT=high          # codex / opencode only
PLAN_REVIEWER=codex:gpt-6-astra   # second-model plan review; no default
CIRCUIT_BREAKER_NO_CHANGE_THRESHOLD=3
CIRCUIT_BREAKER_SAME_ERROR_THRESHOLD=5
CIRCUIT_BREAKER_NO_COMMIT_THRESHOLD=5
ITERATION_TIMEOUT=900  # 15 minutes; kills the agent (and its child processes) if it hangs
```

Precedence: command-line flags > environment variables > `.walph/config` > harness defaults.

### Environment Variables

```bash
export WALPH_HARNESS=codex
export WALPH_MAX_ITERATIONS=100
export WALPH_MODEL_BUILD="opus"  # Use Opus for building too
export WALPH_MODEL_VERIFY="opus"
export WALPH_REASONING_EFFORT=high
export WALPH_PLAN_REVIEWER=claude:opus
export WALPH_ITERATION_TIMEOUT=1200  # 20 minutes per iteration
export WALPH_SKIP_VERIFY=true    # Don't auto-run verify after build
```

The per-session summary CSV in `.walph/logs/` records, per iteration, the harness, model, duration, cost (blank when the harness reports none), tokens in/out, and whether the agent's event stream completed.

## Circuit Breaker

Walph automatically stops when Claude appears stuck:

| Trigger         | Threshold    | Meaning                     |
|-----------------|--------------|------------------------------|
| No file changes | 3 iterations | Claude isn't producing code |
| Same error      | 5 times      | Stuck on the same problem   |
| No commits      | 5 iterations | Tasks aren't completing     |

Reset with `walph reset`, then check your specs for clarity.

## Tips

1. **Start small** - Your first Walph project should be simple
2. **Review the plan** - Edit `IMPLEMENTATION_PLAN.md` before building if tasks look wrong
3. **Watch the logs** - `tail -f .walph/logs/*.log`
4. **Embrace commits** - Each task = one commit. This is good for review and rollback
5. **Iterate on specs** - If Claude struggles, your specs probably need more detail

## Troubleshooting

### Circuit breaker keeps triggering
- Are specs specific enough? Include examples.
- Is `AGENTS.md` correct? Try running build/test commands manually.
- Run `walph reset` to clear state.

### Claude keeps making the same mistake
- Add explicit constraints to your spec
- Check if there's a conflicting requirement
- Look at the logs for what Claude is attempting

### Rate limit hit
Walph will prompt you: wait, exit, or continue. Usually best to wait.

## Jeeroy Lenkins - Document-to-Spec Converter

> "At least I have chicken." - Jeeroy Lenkins

**Jeeroy Lenkins** is a companion tool that converts existing project documentation into Walph-compatible spec files. Got a pile of Word docs, PDFs, or PowerPoints describing what to build? Jeeroy reads them, asks clarifying questions, and generates properly formatted specs.

### How It Works

```
  Documents (any format)          Walph Specs
  ┌──────────┐                    ┌──────────┐
  │ .docx    │                    │ specs/   │
  │ .pdf     │───> Jeeroy ───>    │ *.md     │───> walph plan -> build
  │ .pptx    │    (Claude)        │          │
  │ .md/.txt │                    └──────────┘
  └──────────┘
```

1. **Convert** - Jeeroy converts all documents to markdown (via pandoc)
2. **Analyze** - Claude reads everything and identifies features, gaps, and questions
3. **Q&A** - Claude asks you clarifying questions interactively, and records the answers in `specs/decisions.md` so build iterations can consult them
4. **Generate** - Produces properly formatted spec files in `specs/`, then lints them for missing sections
5. **LFG** (optional) - Chains directly into `walph setup → plan → build`. Before building, it confirms the plan actually has tasks and (unless `--skip-qa`) shows you the task list for a quick yes/no review

### Usage

```bash
# Basic: analyze docs and generate specs
jeeroy ./client-docs

# Target a specific project
jeeroy ./client-docs --project ./my-new-api --stack node

# Full autonomous mode (hold my beer)
jeeroy ./client-docs --project ./my-new-api --lfg

# Skip questions, just generate best-effort specs
jeeroy ./client-docs --skip-qa --lfg

# Run everything on Codex, and have Claude Opus review the plan before building
jeeroy ./client-docs --project ./my-new-api --lfg --harness codex --reviewer claude:opus
```

`--harness` (or `JEEROY_HARNESS`) selects the agent CLI for analysis, Q&A, and the chained Walph phases; `--model` (or `JEEROY_MODEL`) overrides the model. Analysis and `--skip-qa` generation run with restricted access; the interactive Q&A runs with full access because it writes the spec files.

### Supported Formats

| Format       | Extension                    | Method                       |
|--------------|------------------------------|------------------------------|
| Markdown     | `.md`                        | Direct read                  |
| Plain text   | `.txt`                       | Direct read                  |
| Word         | `.docx`, `.doc`              | Pandoc                       |
| PowerPoint   | `.pptx`, `.ppt`              | Pandoc                       |
| PDF          | `.pdf`                       | Pandoc / pdftotext           |
| HTML         | `.html`, `.htm`              | Pandoc                       |
| Rich Text    | `.rtf`                       | Pandoc                       |
| OpenDocument | `.odt`                       | Pandoc                       |
| EPUB         | `.epub`                      | Pandoc                       |
| Images       | `.jpg`, `.png`, `.gif`, etc. | File reference (Claude vision) |
| Code         | `.js`, `.py`, `.ts`, etc.    | Direct read (fenced)         |
| Archives     | `.zip`                       | Extract and process contents |

### Requirements

- **An agent CLI** (required) - claude, codex, or opencode
- **jq** (required)
- **pandoc** (required for non-markdown formats) - `brew install pandoc`
- **chrome-devtools MCP** (recommended for UI projects) - For browser-based UI testing

### Architecture Defaults

When designing new projects, Jeeroy defaults to:
- **Docker-first**: Uses Docker Compose with containerized databases/services
- **UI testing included**: Specs include E2E testing requirements using chrome-devtools MCP

## Good Bunny - Autonomous Code Quality Reviewer

> "I'm a good bunny." - Good Bunny

**Good Bunny** is a companion tool that autonomously audits and fixes code quality issues on **any project**. No setup required — just run it in your project directory.

### How It Works

```
  Your Project                    REVIEW_FINDINGS.md
  ┌──────────┐                    ┌──────────────────┐
  │ src/     │                    │ - [ ] [SECURITY] │
  │ tests/   │──> goodbunny ──>   │ - [ ] [DRY]      │──> goodbunny fix
  │ etc.     │    audit (Opus)    │ - [ ] [TESTING]  │    (Sonnet)
  └──────────┘                    └──────────────────┘
                                          │
                                          v
                                  ┌──────────────────┐
                                  │ Fixed code +     │
                                  │ git commits      │
                                  └──────────────────┘
```

1. **Audit** (Opus) - Good Bunny reads your project and reviews it against 9 code quality categories, generating `REVIEW_FINDINGS.md` with prioritized, actionable findings
2. **Fix** (Sonnet) - Good Bunny picks ONE finding per iteration, fixes it, runs tests, marks it done, and commits — repeating until all findings are addressed
3. **Analyze** (Opus) - Good Bunny documents the entire codebase, generating `GOODBUNNY_REPORT.md` — a 12-section guide covering architecture, setup, patterns, testing, and more. If a prior audit exists, findings are incorporated automatically

### Works on Any Project

Good Bunny needs no configuration files, no specs, no AGENTS.md. It auto-creates a `.goodbunny/` directory on first run and works with whatever it finds. If your project has an `AGENTS.md` with test commands, it'll use those. Otherwise, it detects common patterns by language.

### Usage

```bash
# Full audit
cd your-project
goodbunny audit

# Review REVIEW_FINDINGS.md, remove any false positives, then:
goodbunny fix

# Focused audit (specific categories or files)
goodbunny audit --categories security,testing
goodbunny audit --files src/api/

# Limit fix iterations
goodbunny fix --max-iterations 10

# Generate codebase documentation
goodbunny analyze
goodbunny analyze --files lib/    # Scope to specific directory

# Run the review loop on Codex (gpt-6-astra audits, gpt-5.6-sol fixes)
goodbunny audit --harness codex
goodbunny fix --harness codex
```

### Review Categories

| Category        | What It Checks                                           |
|-----------------|----------------------------------------------------------|
| Security        | OWASP Top 10, hardcoded secrets, injection, auth         |
| Architecture    | SRP, god modules, circular deps, coupling                |
| Complexity      | Long functions, deep nesting, complex booleans           |
| DRY             | Duplicated code, copy-paste patterns                     |
| KISS            | Over-engineering, unnecessary abstraction                |
| Dependencies    | Outdated/vulnerable packages, unused deps                |
| Error Handling  | Missing catches, swallowed errors, validation            |
| Testing         | Missing tests, coverage gaps, brittle tests              |
| Spec Compliance | Implementation vs `specs/` acceptance criteria (Walph-built projects) |

### Configuration

Good Bunny auto-creates `.goodbunny/config` on first run. Override via environment variables:

```bash
export GOODBUNNY_HARNESS=codex            # or --harness / HARNESS= in .goodbunny/config
export GOODBUNNY_MAX_ITERATIONS=50
export GOODBUNNY_MODEL_AUDIT="opus"       # defaults depend on the harness
export GOODBUNNY_MODEL_FIX="sonnet"
export GOODBUNNY_MODEL_ANALYZE="opus"
export GOODBUNNY_REASONING_EFFORT=high    # codex / opencode only
export GOODBUNNY_ITERATION_TIMEOUT=1200
```

## Inspiration & Background

Walph Riggum is inspired by the **Ralph Wiggum technique** pioneered by Geoffrey Huntley - a simple bash loop that repeatedly feeds Claude a prompt until completion. The name comes from The Simpsons character who embodies persistent iteration despite setbacks.

> "The technique is deterministically bad in an undeterministic world. It's better to fail predictably than succeed unpredictably."

The original Ralph Wiggum approach uses a Stop hook to intercept Claude's exit and re-feed the same prompt. Each iteration sees modified files from previous runs. This has produced remarkable results - developers completing $50K contracts for $297 in API costs, running loops overnight to wake up to working code.

**But there's a catch**: context compaction. As Huntley noted, *"Compaction is the devil."* In long-running sessions, Claude's context window fills up and gets summarized, potentially losing the original goal.

**Walph takes a different approach**: instead of fighting context compaction, we embrace fresh context. Each iteration starts clean. Memory lives in files (`IMPLEMENTATION_PLAN.md`, git commits), not in Claude's conversation history. This trades some continuity for predictability - Claude always sees the full, uncompacted state.

### Further Reading

- [From Client Docs to Working Code](https://medium.com/@artmorales/from-client-docs-to-working-code-building-software-with-walph-and-jeeroy-56a1ba1718c3) - Blog post on how Walph and Jeeroy work together
- [Original Reddit breakdown](https://www.reddit.com/r/ClaudeAI/comments/1qlqaub/my_ralph_wiggum_breakdown_just_got_endorsed_as/) - The post that inspired this project
- [Ralph Wiggum on Awesome Claude](https://awesomeclaude.ai/ralph-wiggum) - Community resources
- [11 Tips for AI Coding with Ralph Wiggum](https://www.aihero.dev/tips-for-ai-coding-with-ralph-wiggum) - Practical guidance
- [A Brief History of Ralph](https://www.humanlayer.dev/blog/brief-history-of-ralph) - How the technique evolved

## Philosophy

Walph is built on the idea that **the best AI coding assistant is one that works like a disciplined developer**:

- Do one thing at a time
- Test your work
- Commit your changes
- Start fresh on the next task

This approach scales to large projects where context management becomes critical. Instead of fighting context limits, Walph works with them.

## Security Considerations

**Walph runs the agent with all permissions bypassed** (`--dangerously-skip-permissions` on Claude Code, `--dangerously-bypass-approvals-and-sandbox` on Codex, `--auto` on OpenCode), which means:
- The agent can read, write, and delete any files in your project
- The agent can execute any shell commands
- The agent can make network requests

This is necessary for autonomous operation but means you should:

1. **Review specs carefully** - the agent will do what you ask
2. **Use on trusted codebases** - Don't run on repos with sensitive credentials
3. **Run in isolated environments** - Consider Docker or VMs for untrusted projects
4. **Review commits** - Each task creates a git commit you can inspect

The default Docker credentials (`postgres:postgres`) are for development only. Change them for any real deployment.

## License

MIT

## Development

```bash
shellcheck -x -s bash walph.sh goodbunny.sh jeeroy.sh lib/*.sh   # lint
tests/run_tests.sh                                              # parser + fake-CLI integration tests (bash 3.2 compatible)
```

The integration tests never call a real agent: `tests/fake-bins/` contains a scenario-driven fake that impersonates all three CLIs.

## Contributing

Issues and PRs welcome. If you're adding a feature, write a spec first!
