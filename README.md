# Walph Riggum

An autonomous coding loop that uses Claude to plan and build software projects.

> "Me fail English? That's unpossible!" - Walph Riggum

## Overview

Walph Riggum is a bash-based orchestration tool that runs Claude in an autonomous loop to:
1. **Plan** - Analyze specifications and generate implementation plans
2. **Build** - Implement tasks one at a time, test, and commit

### Key Features

- **Dual-mode operation**: Planning mode (Opus) and Building mode (Sonnet)
- **Circuit breaker**: Automatically stops when stuck
- **Iteration limits**: Configurable max iterations
- **Rate limit handling**: Graceful handling of API limits
- **Structured completion signals**: Clear communication of progress
- **Git integration**: Commits after each completed task
- **Docker templates**: Quick setup for Node.js and Python projects

## Installation

### Option 1: Global Install

```bash
./install.sh
```

This creates `ralph` and `walph-init` commands in `~/bin`.

### Option 2: Direct Usage

Run scripts directly from the repository:

```bash
./walph.sh plan
./walph.sh build
```

## Quick Start

> **See [QUICKSTART.md](QUICKSTART.md) for detailed instructions and templates.**

### 1. Initialize a Project

```bash
# Create new project with Node.js stack
./init.sh my-project --stack node

# Or with Python
./init.sh my-project --stack python

# With Docker support
./init.sh my-project --stack node --docker
```

### 2. Write Specifications

Edit files in `specs/` to describe what you want to build:

```bash
cd my-project
# Edit specs/api.md, specs/features.md, etc.
```

### 3. Generate Plan

```bash
../walph.sh plan --max-iterations 3
```

Review and edit `IMPLEMENTATION_PLAN.md` as needed.

### 4. Build

```bash
../walph.sh build --max-iterations 50
```

Watch as Claude implements your project task by task!

## Commands

```bash
walph.sh <command> [options]

Commands:
  plan              Generate/update implementation plan
  build             Implement tasks from plan (default)
  status            Show current state and progress
  reset             Reset circuit breaker and state

Options:
  --max-iterations N    Maximum iterations (default: 50)
  --model MODEL         Override model for this run
  --monitor             Enable tmux monitoring view
  --dry-run             Show what would run without executing
  -v, --verbose         Verbose output
  -h, --help            Show help
  --version             Show version
```

## Project Structure

After initialization, your project will have:

```
my-project/
├── .walph/
│   ├── config                  # Configuration overrides
│   ├── logs/                   # Session logs
│   ├── state/                  # Circuit breaker state
│   ├── PROMPT_plan.md         # Planning prompt (customizable)
│   └── PROMPT_build.md        # Building prompt (customizable)
├── specs/
│   └── example.md             # Specification files
├── AGENTS.md                   # Build/test commands for Claude
├── IMPLEMENTATION_PLAN.md      # Generated/maintained task list
└── .gitignore
```

## Configuration

### .walph/config

```bash
# Maximum iterations
MAX_ITERATIONS=50

# Models (use aliases or full names)
MODEL_PLAN="opus"
MODEL_BUILD="sonnet"

# Circuit breaker thresholds
CIRCUIT_BREAKER_NO_CHANGE_THRESHOLD=3
CIRCUIT_BREAKER_SAME_ERROR_THRESHOLD=5
CIRCUIT_BREAKER_NO_COMMIT_THRESHOLD=5
```

### Environment Variables

```bash
export WALPH_MAX_ITERATIONS=100
export WALPH_MODEL_PLAN="opus"
export WALPH_MODEL_BUILD="sonnet"
```

## How It Works

### Planning Mode

1. Reads all files in `specs/`
2. Reads existing code and `AGENTS.md`
3. Performs gap analysis
4. Generates/updates `IMPLEMENTATION_PLAN.md`

### Building Mode

1. Reads `IMPLEMENTATION_PLAN.md`
2. Picks first uncompleted task
3. Implements the task
4. Runs tests and lint
5. Marks task complete
6. Commits changes
7. Repeats until done or limit reached

### Circuit Breaker

The loop stops automatically when:
- No file changes for 3 consecutive iterations
- Same error repeated 5 times
- No commits for 5 iterations (build mode)
- Claude signals `WALPH_STUCK`

Reset with: `walph.sh reset`

### Completion Signal

Claude outputs a status block each iteration:

```
WALPH_STATUS
completion_level: HIGH
tasks_remaining: 0
current_task: All tasks complete
EXIT_SIGNAL: true
WALPH_STATUS_END
```

The loop exits when `completion_level: HIGH` AND `EXIT_SIGNAL: true`.

## Customization

### Custom Prompts

Copy and modify the prompts in `.walph/`:
- `PROMPT_plan.md` - Planning instructions
- `PROMPT_build.md` - Building instructions

### AGENTS.md

Tell Claude about your project:

```markdown
# Project: My App

## Build Commands
npm run build

## Test Commands
npm test

## Lint Commands
npm run lint

## Notes for Claude
- Use TypeScript strict mode
- Follow existing patterns in src/
```

## Tips

1. **Start small**: Begin with detailed specs for a small feature
2. **Review plans**: Always review `IMPLEMENTATION_PLAN.md` before building
3. **Iterate**: Run planning multiple times to refine the plan
4. **Monitor**: Use `--monitor` in tmux for visibility
5. **Commit often**: The system commits after each task - embrace it

## Troubleshooting

### Circuit Breaker Keeps Triggering

```bash
walph.sh reset
```

Then check:
- Are specs clear enough?
- Is `AGENTS.md` accurate?
- Are tests actually passing locally?

### Rate Limit Hit

The script will prompt you with options:
1. Wait and retry
2. Exit and resume later
3. Continue anyway

### Claude Stuck

Look for `WALPH_STUCK` in logs. Common causes:
- Unclear requirements
- Missing dependencies
- Conflicting specs

## License

MIT

## Contributing

Issues and PRs welcome! Please read the specs carefully before implementing.
