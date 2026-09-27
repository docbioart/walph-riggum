<!-- Shared engineering principles, injected into every prompt template.
     Edit this file once; every mode (plan, build, verify, audit, jeeroy) picks it up.
     Projects can override with their own copy in .walph/PRINCIPLES.md -->

### One-Shot Session (Critical)

**Your session ENDS the moment you stop responding. Nothing survives it.**

- **NEVER end your turn to "wait" for anything** — a background test run, a container starting, a watcher, a long build. The instant you stop, those processes are killed and a fresh session starts with no memory of them. "I'll wait for the pytest run to finish and follow up" is an infinite loop that burns money: the next session will start the same run and wait again.
- **Run everything to completion in the foreground, inside your turn.** If tests are slow (containers, migrations), start them and block on them. Long waits inside your turn are fine — the loop has a generous timeout.
- **If something genuinely cannot finish within your turn**, do not pretend to wait: pick a smaller verifiable slice, commit what is truly done, and describe the remaining work precisely in the plan so the next session can continue.
- **Always finish your turn with a commit for completed work and the status block** — a turn that ends without either is a wasted iteration and pushes the loop toward its circuit breaker.

### Code Quality

- **DRY (Don't Repeat Yourself)** - Before writing new code, check if similar logic exists. Extract shared code into reusable functions/modules. Never copy-paste code blocks.
- **KISS (Keep It Simple, Stupid)** - Write the simplest code that works. Avoid clever tricks, premature optimization, or unnecessary abstraction.
- **YAGNI / No Over-Engineering** - Don't add features, config options, or flexibility not in the specs. Don't create abstractions for single-use cases. Three similar lines are better than a premature helper function.

### Environment Configuration (Critical)

**NEVER hardcode any of the following — not in source code, not in config files (`config.py`, `config.js`, `settings.py`, `constants.ts`, etc.), not anywhere in the repo:**
- Server addresses, hostnames, or URLs (API endpoints, database hosts, etc.)
- API keys, tokens, or secrets
- Database connection strings, usernames, or passwords
- Port numbers
- Environment-specific values (dev/staging/prod)

Rules:
1. **Read from environment** - Use `process.env.VAR_NAME` (Node), `os.environ['VAR_NAME']` (Python), etc.
2. **Config files must be thin wrappers** - A `config.py`, `config.js`, or similar is only valid if every value comes from environment variables:
   ```python
   # config.py - CORRECT
   import os
   DATABASE_URL = os.environ["DATABASE_URL"]
   API_KEY = os.environ["API_KEY"]
   PORT = int(os.environ.get("PORT", "3000"))
   ```
   ```python
   # config.py - WRONG (hardcoded values)
   DATABASE_URL = "postgresql://localhost:5432/mydb"
   API_KEY = "sk-abc123"
   PORT = 3000
   ```
3. **Defaults only for non-sensitive values** - `process.env.PORT || 3000` is OK; never default API keys.
4. **`.env` is the single source of truth** - Every variable used in the project must be templated in `.env.example` with placeholder values and comments.
5. **Never commit `.env`** - `.gitignore` must include `.env` (but NOT `.env.example`).

### Docker & Ports (Critical)

- **Docker-first for new projects** - Docker Compose for local development, containerized databases/services (Postgres, Redis, etc.), health checks, graceful shutdown.
- **Never assume default ports are available** - Common ports (3000, 5432, 8080, 6379) are often in use. All exposed ports must be configurable via environment variables:
  ```yaml
  ports:
    - "${APP_PORT:-3000}:3000"
    - "${DB_PORT:-5432}:5432"
  ```
- Document all ports in `.env.example`. Prefer less-common defaults (e.g., 3001, 5433) when sensible.
- If a container fails to start, check for a port conflict first: `lsof -i :<port>`.

### Frontend/Backend Contract (Critical)

If the project has both a frontend and a backend (or any API boundary):

1. **Explicit API contract** - Every endpoint must specify: HTTP method, path, request body/params, response shape (field names and types), status codes, and error response shapes. Both sides must reference the same contract.
2. **Shared types** - If a shared types file, OpenAPI spec, or API schema exists, import from it. Never duplicate type definitions across frontend and backend. If defining a new API and no shared types exist, create them in a shared location.
3. **Field name consistency** - Identical field names on both sides. If the backend returns `user_id`, the frontend must expect `user_id` (not `userId`) unless there is an explicit, documented mapping layer.
4. **Status codes and error shapes** - Frontend error handling must match the error responses the backend actually sends. Read the other side's code to verify.
5. **Environment variable alignment** - Frontend and backend must use the same env var names for shared config (e.g., both use `API_BASE_URL`, not `API_URL` on one side and `BACKEND_URL` on the other).
6. **Contract validation** - A contract test or schema validation step should catch mismatches before they reach production.

### UI Testing (Critical)

**Compile success does NOT mean the UI works.** If the project has a UI (web, mobile, desktop), actual browser testing is required using the chrome-devtools MCP server's tools (tool names carry a harness-specific prefix such as `mcp__chrome-devtools__`; the tools themselves are the same):

```
1. navigate_page to the dev server URL
2. take_snapshot to see the page state
3. click on interactive elements
4. fill for form inputs
5. list_console_messages to check for errors
```

Never declare UI work complete without verifying it renders and functions in a real browser.
