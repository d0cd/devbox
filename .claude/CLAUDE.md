# devbox — Repository Context

## What This Is

devbox is an isolated, containerized development environment. It combines container isolation, dual-layer network enforcement (iptables + mitmproxy), API observability (SQLite logging via `devbox logs`), and pre-installed AI/dev tools (Claude Code, OpenCode, Gemini CLI, Codex, neovim). The container is infrastructure — users exec into it.

## Key Documents

- `docs/DESIGN.md` — architecture, security model, design decisions
- `docs/PLAN.md` — phased implementation plan with exit criteria and status
- `README.md` — quickstart and user-facing documentation
- `CREDITS.md` — attribution for source projects

## Tech Stack

- **Shell:** Bash (CLI, lib scripts, profiles)
- **Python:** mitmproxy addons (enforcer.py, logger.py)
- **Docker:** Ubuntu 24.04 agent container + Python 3.12-slim proxy sidecar
- **Orchestration:** Docker Compose v2
- **Tools in container:** Claude Code, OpenCode (with PAL MCP), Gemini CLI, Codex, neovim

## Architecture

Two-container stack per project:
1. **Agent container** — holds open as isolated environment, all dev tools, firewalled (internal network only). Users exec in via `devbox shell`.
2. **Proxy sidecar** — mitmproxy enforcing domain allowlist + logging to SQLite (dual network: internal + external)

Network isolation: `sandbox` network is `internal: true` (agent only), proxy has a second `external` network for internet access.

## Code Conventions

- Shell scripts: bash with `set -euo pipefail`
- Use `shellcheck` for linting all `.sh` files
- Functions prefixed by module name (e.g., `container_start`, `profile_list`, `allowlist_add`)
- All scripts and profiles must be idempotent
- Validate all user input (profile names, domain names) before use
- Python addons: type hints, minimal dependencies
- No `fnmatch` or regex on user input — use fixed-string matching or explicit validation
- Command functions use `return 1` (not `exit 1`) for recoverable errors

## Security Rules

- Never bake secrets into Docker images
- Credentials injected via `--env-file` at runtime only
- Config mounted read-only into containers
- Agent container cannot modify its own network policy
- All network egress logged to SQLite
- Firewall initialization is mandatory — container refuses to start without it
- DNS restricted to Docker embedded resolver (127.0.0.11)
- Secrets files created with restrictive permissions (umask 077)
- Profile names and domain names validated against strict patterns before use
- API logs queryable via `devbox logs` (SQLite on host)

## Repository Layout

```
devbox                  # CLI entry point (bash)
main.sh                 # Installer
Dockerfile              # Agent container image
entrypoint.sh           # Agent container entrypoint (holds container open)
docker-compose.yml      # Two-service stack definition
proxy/                  # Proxy sidecar
  Dockerfile            # Proxy image
  entrypoint.sh         # Proxy entrypoint (CA gen + mitmproxy)
  enforcer.py           # Domain allowlist addon
  logger.py             # SQLite logging addon
lib/                    # Shell library modules
  container.sh          # Container lifecycle (start/stop/shell/status)
  ui.sh                 # TUI helpers (info/warn/error/confirm)
  profile.sh            # Profile management
  allowlist.sh          # Allowlist management
  firewall.sh           # iptables initialization
tooling/profiles/       # Language profile scripts (rust/python/node/go)
config/                 # Default OpenCode + PAL MCP configuration
  opencode.json
  pal/systemprompts/clink/  # Subagent role prompts
templates/              # Default configs (policy.yml, zshrc, tmux.conf, AGENTS.md, private-overlay.Dockerfile)
docs/                   # DESIGN.md, PLAN.md
.github/workflows/      # CI (lint, build with caching, smoke test)
```

## Attribution

Built on MIT-licensed work from: claudebox (RchGrav), agent-sandbox (mattolson), claude-container (nezhar). See CREDITS.md.
