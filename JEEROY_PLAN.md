# Jeeroy Lenkins - Implementation Plan

## Overview

Jeeroy Lenkins is a companion tool to Walph Riggum that converts arbitrary documentation (docx, doc, md, txt, ppt, pdf, etc.) into Walph-compatible specs. It reads docs from a directory, uses Claude CLI to analyze and understand them, asks clarifying questions interactively, then generates properly formatted spec files in `specs/`. With the `--lfg` flag, it chains directly into Walph for a fully autonomous one-click experience.

**Name origin:** A play on "Leeroy Jenkins" - embodying the "just send it" / "hold my beer" philosophy.

## Architecture

Jeeroy lives in the same `ralphwiggum/` repository alongside Walph. It reuses Walph's shared libraries (`lib/logging.sh`, `lib/utils.sh`, `lib/config.sh`) and follows the same patterns.

```
ralphwiggum/
├── jeeroy.sh                              # Main orchestrator (NEW)
├── lib/
│   ├── converter.sh                       # Document conversion via pandoc (NEW)
│   ├── logging.sh                         # Shared (existing)
│   ├── utils.sh                           # Shared (existing)
│   └── config.sh                          # Shared (existing)
├── templates/
│   ├── PROMPT_jeeroy_analyze.md           # Analysis prompt (NEW)
│   └── PROMPT_jeeroy_qa.md               # Q&A prompt (NEW)
├── walph.sh                               # Existing
├── install.sh                             # Updated to include jeeroy
└── README.md                              # Updated with Jeeroy section
```

## Command Interface

```bash
jeeroy <docs-dir> [options]

# Options:
#   --project <path>     Target project directory (default: current directory)
#   --stack <type>        Stack hint: node, python, swift, kotlin, go, rust
#   --lfg                 "Let's F***ing Go" - auto-chain into walph setup → plan → build
#   --skip-qa             Skip the interactive Q&A phase
#   --model <name>        Override Claude model (default: opus)
#   --max-specs <n>       Max number of spec files to generate (default: no limit)
#   --dry-run             Show what would happen without executing
#   -v, --verbose         Verbose output
#   -h, --help            Show help
```

### Example Usage

```bash
# Basic: analyze docs and generate specs
jeeroy ./client-docs

# With project target
jeeroy ./client-docs --project ./my-new-api --stack node

# Full auto: analyze, generate specs, setup walph, plan, build
jeeroy ./client-docs --project ./my-new-api --lfg

# Skip questions, just do best-effort
jeeroy ./client-docs --skip-qa --lfg
```

## Files to Create/Modify

### 1. `jeeroy.sh` - Main orchestrator
### 2. `lib/converter.sh` - Document conversion via pandoc
### 3. `templates/PROMPT_jeeroy_analyze.md` - Analysis prompt
### 4. `templates/PROMPT_jeeroy_qa.md` - Interactive Q&A prompt
### 5. `install.sh` - Add jeeroy wrapper
### 6. `README.md` - Add Jeeroy section
