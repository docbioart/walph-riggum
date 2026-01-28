# Walph Riggum

An autonomous coding loop that runs Claude from the *outside* to build software projects with clean context every iteration.

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

| Approach | Context | Memory | Best For |
|----------|---------|--------|----------|
| **Interactive Claude Code** | Accumulates | In conversation | Small tasks, exploration |
| **Claude Code plugins** | Accumulates | In conversation | Extending functionality |
| **Walph Riggum** | Fresh each iteration | Files + Git | Large projects, autonomy |

Walph is not a Claude Code plugin. It's an external orchestrator that *runs* Claude Code repeatedly, giving each invocation exactly what it needs and nothing more.

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                         WALPH LOOP                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   ┌─────────┐     ┌──────────────┐     ┌─────────┐             │
│   │  specs/ │────▶│  walph plan  │────▶│  PLAN   │             │
│   │  (you)  │     │   (Opus)     │     │  .md    │             │
│   └─────────┘     └──────────────┘     └────┬────┘             │
│                                             │                   │
│                                             ▼                   │
│   ┌─────────┐     ┌──────────────┐     ┌─────────┐             │
│   │  Code   │◀────│ walph build  │◀────│  PLAN   │             │
│   │  + Git  │     │  (Sonnet)    │     │  .md    │             │
│   └─────────┘     └──────┬───────┘     └─────────┘             │
│                          │                                      │
│                          │ loop until done                      │
│                          │ or stuck                             │
│                          ▼                                      │
│                   ┌──────────────┐                              │
│                   │   Complete   │                              │
│                   └──────────────┘                              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

1. **You write specs** in `specs/*.md` - describe what you want built
2. **Plan phase** (Opus) - Claude reads specs and generates a task list in `IMPLEMENTATION_PLAN.md`
3. **Build phase** (Sonnet) - Claude picks ONE task, implements it, runs tests, marks it done, commits
4. **Loop** - Walph restarts Claude with the updated plan, repeating until all tasks are complete

Each build iteration is independent. Claude reads the current state from files, does one task, saves its work. No context accumulation, no memory degradation.

## Features

- **Dual-model strategy**: Opus for planning (smarter), Sonnet for building (faster)
- **Circuit breaker**: Auto-stops if Claude gets stuck (no changes, same error, no commits)
- **Git-native**: Every completed task becomes a commit - easy to review, revert, or continue
- **Stack templates**: Quick setup for Node.js, Python, Swift, Kotlin, Capacitor, and more
- **Customizable prompts**: Modify `.walph/PROMPT_*.md` to change Claude's behavior
- **Existing project support**: `walph setup` adds Walph to any project

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
│   ├── logs/               # Session logs
│   └── state/              # Circuit breaker state
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
walph plan                      # Generate tasks from specs
walph build                     # Implement tasks (the main loop)
walph status                    # Show progress
walph reset                     # Clear stuck state
```

### Options

```
--max-iterations N    Limit iterations (default: 50)
--model <name>        Override model (opus, sonnet)
--monitor             Tmux split with logs + git status
--dry-run             Show what would run
```

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
MAX_ITERATIONS=50
MODEL_PLAN="opus"
MODEL_BUILD="sonnet"
CIRCUIT_BREAKER_NO_CHANGE_THRESHOLD=3
CIRCUIT_BREAKER_SAME_ERROR_THRESHOLD=5
CIRCUIT_BREAKER_NO_COMMIT_THRESHOLD=5
```

### Environment Variables

```bash
export WALPH_MAX_ITERATIONS=100
export WALPH_MODEL_BUILD="opus"  # Use Opus for building too
```

## Circuit Breaker

Walph automatically stops when Claude appears stuck:

| Trigger | Threshold | Meaning |
|---------|-----------|---------|
| No file changes | 3 iterations | Claude isn't producing code |
| Same error | 5 times | Stuck on the same problem |
| No commits | 5 iterations | Tasks aren't completing |

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

## Inspiration & Background

Walph Riggum is inspired by the **Ralph Wiggum technique** pioneered by Geoffrey Huntley - a simple bash loop that repeatedly feeds Claude a prompt until completion. The name comes from The Simpsons character who embodies persistent iteration despite setbacks.

> "The technique is deterministically bad in an undeterministic world. It's better to fail predictably than succeed unpredictably."

The original Ralph Wiggum approach uses a Stop hook to intercept Claude's exit and re-feed the same prompt. Each iteration sees modified files from previous runs. This has produced remarkable results - developers completing $50K contracts for $297 in API costs, running loops overnight to wake up to working code.

**But there's a catch**: context compaction. As Huntley noted, *"Compaction is the devil."* In long-running sessions, Claude's context window fills up and gets summarized, potentially losing the original goal.

**Walph takes a different approach**: instead of fighting context compaction, we embrace fresh context. Each iteration starts clean. Memory lives in files (`IMPLEMENTATION_PLAN.md`, git commits), not in Claude's conversation history. This trades some continuity for predictability - Claude always sees the full, uncompacted state.

### Further Reading

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

## License

MIT

## Contributing

Issues and PRs welcome. If you're adding a feature, write a spec first!
