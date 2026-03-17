# devbox — Design Document

## Overview

devbox is an isolated, containerized development environment. Each project runs in its own Docker container with strict network enforcement, API observability, and all AI/dev tools pre-installed. The container is infrastructure — users exec into it to run claude, opencode, nvim, or any other tool.

### Core Principles

1. **Isolation by default** — each project gets its own container with no host filesystem access beyond the project directory.
2. **Defense in depth** — dual-layer network enforcement (iptables + mitmproxy) ensures no unapproved egress, even from compromised agents or plugins.
3. **Tool-agnostic** — Claude Code, OpenCode, Gemini CLI, Codex, nvim — all run inside the same isolated environment. No tool is privileged over another.
4. **Observable** — every API call is logged to SQLite, queryable via `devbox logs`.
5. **Zero trust for agents** — credentials injected at runtime, config mounted read-only, network policy controlled exclusively from the host.

### Attribution

devbox builds on three open-source projects (all MIT-licensed):

- **claudebox** (RchGrav) — profile system, per-project container architecture, allowlist CLI, DX patterns.
- **agent-sandbox** (mattolson) — dual-layer network enforcement: mitmproxy sidecar + iptables.
- **claude-container** (nezhar) — API logging proxy pattern and SQLite observability.

---

## Architecture

```
Host (tmux, your workflow)
    │
    ├── devbox start          # starts environment
    ├── devbox shell          # exec into container (multiple panes)
    │
    ▼
┌────────────────────────────────────────────────────────┐
│  Agent Container (per-project, persistent)              │
│                                                        │
│  Available tools (user runs directly):                 │
│  ├── claude                Claude Code sessions        │
│  ├── opencode              OpenCode (PAL MCP dispatch) │
│  ├── nvim                  Neovim (private config)     │
│  ├── gemini                Gemini CLI (1M context)     │
│  ├── codex                 Codex CLI                   │
│  └── zsh                   Shell with dev tooling      │
│                                                        │
│  Network stack:                                        │
│  iptables → mitmproxy enforcer → approved domains only │
│           ↓                                            │
│  logging proxy → SQLite → devbox logs                   │
│                                                        │
│  Mounts:                                               │
│  /workspace     ← project dir only (rw)                │
│  /devbox        ← global config (ro)                   │
└────────────────────────────────────────────────────────┘
         │ HTTP_PROXY / HTTPS_PROXY
         ▼
┌─────────────────────────┐
│  Proxy Sidecar          │
│  mitmproxy enforcer.py  │  ← enforces domain allowlist
│  + logging middleware   │  ← logs all API calls to SQLite
└─────────────────────────┘
```

The proxy sidecar is a **separate trusted container**. The agent container has no internet access except through it. Even if an agent is compromised or prompt-injected, it cannot exfiltrate data to an unapproved destination because iptables blocks all direct outbound — the proxy is the only egress path.

---

## Security Architecture

### Layer 1 — Filesystem (Docker mounts)

Only `/workspace` (the project directory) is mounted read-write. Global config is read-only. No access to `~/.ssh`, `~/.aws`, or other projects.

```
-v "${PROJECT}":/workspace:rw
-v ~/.config/devbox:/devbox:ro
```

### Layer 2 — Network (dual enforcement)

The agent container has no direct internet access. All outbound is blocked by iptables except to the Docker bridge where the proxy sidecar runs.

```bash
# lib/firewall.sh (sourced by entrypoint.sh at container startup)
iptables -P OUTPUT DROP
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -d $DEVBOX_BRIDGE_SUBNET -p tcp --dport 8080 -j ACCEPT  # proxy
iptables -A OUTPUT -d 127.0.0.11 -p udp --dport 53 -j ACCEPT              # DNS
iptables -A OUTPUT -d 127.0.0.11 -p tcp --dport 53 -j ACCEPT              # DNS
```

The mitmproxy sidecar runs `enforcer.py`, checking every HTTP request and HTTPS CONNECT tunnel against the domain allowlist. Non-matching requests receive a 403. The proxy CA cert is installed into the agent container's trust store at startup for full HTTPS inspection.

Dual-layer guarantees:
- Processes respecting `HTTP_PROXY` → stopped at proxy
- Processes ignoring proxy env → stopped at iptables
- No bypass path short of container escape

### Layer 3 — Credentials (environment injection)

API keys injected at runtime via Docker Compose `env_file`. Never baked into images.

The logging proxy captures all outbound API calls. If a prompt injection tricks an agent into exfiltrating credentials in a request body, the log records it.

### Honest Threat Model

- **Git credential scope:** A token granting access to all repos, not just the mounted project. Scope tokens to single repos where possible.
- **Prompt injection via project files:** Malicious comments in dependencies can instruct the agent within approved boundaries. Network layer limits exfiltration destinations but cannot prevent in-boundary actions.
- **Container escape:** Kernel exploits could escape containment. Mitigated by keeping Docker current and never running `--privileged`.
- **Approved domain misuse:** The agent can send arbitrary content to approved domains. Content filtering at the proxy layer is not implemented.

---

## Network Policy

Each project gets its own `policy.yml`, read-only mounted into the proxy. The agent cannot modify it.

```yaml
version: "1"

allowed:
  # Model APIs
  - api.anthropic.com
  - openrouter.ai
  - generativelanguage.googleapis.com
  - api.openai.com

  # Package registries
  - crates.io
  - static.crates.io
  - index.crates.io
  - registry.npmjs.org
  - pypi.org
  - files.pythonhosted.org

  # Code hosting
  - github.com
  - api.github.com
  - "*.githubusercontent.com"

  # System updates
  - security.ubuntu.com
  - archive.ubuntu.com
```

The full default policy (including language toolchain and package manager domains) is in `templates/policy.yml`.

---

## Proxy Sidecar

Two mitmproxy addons chained:

- **enforcer.py** — checks every request against `policy.yml`. Returns 403 for non-allowed domains. Blocks HTTPS CONNECT tunnels to non-allowed hosts.
- **logger.py** — logs every request/response to SQLite (timestamp, method, url, status, request/response bodies). Queryable via `devbox logs` or direct `sqlite3`.

---

## Container Stack

Docker Compose manages two services per project:

- **agent** — Ubuntu 24.04 with Claude Code, OpenCode, Gemini CLI, Codex, GitHub CLI, neovim, zsh/tmux/powerline. Firewall initialized at startup. Holds container open for exec sessions. All traffic routed through proxy.
- **proxy** — Python 3.12 slim with mitmproxy and the two addons (enforcer + logger). Sole egress path for the agent container.

Volumes:
- `proxy-ca` shared volume for the proxy CA certificate
- Project-specific data under `~/.devbox/<project-hash>/`

---

## Multi-Agent Dispatch (via OpenCode)

When using OpenCode inside the container, PAL MCP + clink dispatch is available:

| Task | Dispatch to | Reason |
|------|-------------|--------|
| Security audit | Codex | Fresh context, isolated, no side effects |
| Full codebase review | Gemini CLI | 1M context window |
| Complex debugging | Codex | Strong reasoning, clean slate |
| Architecture decision | PAL consensus | Multi-model cross-check |
| Large log analysis | Gemini CLI | 1M context, fast |
| Quick analysis | Direct (OpenCode) | No overhead |

This is optional — users who prefer Claude Code or direct tool use are not required to use OpenCode's dispatch model.

---

## CLI Interface

```bash
devbox                        # Start environment and open shell
devbox ~/projects/my-app      # Start for specific project
devbox shell                  # Open another shell into running env
devbox profile rust           # Install language profile
devbox allowlist              # View/edit network allowlist
devbox logs                   # Show recent API calls (sqlite3)
devbox info                   # Status / info panel
devbox stop                   # Stop the running container stack
devbox clean --project        # Clean this project's data
devbox clean --all            # Clean everything
devbox rebuild                # Rebuild base image
devbox update                 # Pull latest source and rebuild
devbox help                   # Show help and usage info
```

---

## Private Config Overlay

Users overlay their local dev environment into the container without committing configs to the public repo. The goal: the container should feel identical to your local machine.

Set `DEVBOX_PRIVATE_CONFIGS` to a local directory path or private git URL:

```
your-configs/
├── Dockerfile       # Optional: FROM devbox-agent:latest, pre-build plugins
├── claude/          # → ~/.claude/ (settings.json, hooks, skills)
├── opencode/        # → ~/.config/opencode/ (merged with defaults)
├── nvim/            # → ~/.config/nvim/ (init.lua, lua/, lazy-lock.json)
├── tmux/            # → ~/.config/tmux/ + ~/.tmux.conf (symlinked)
└── .zshrc           # → ~/.zshrc (replaces default devbox zshrc)
```

### Three-phase flow

1. **Host sync** — `sync_private_configs()` symlinks a local directory or clones a git repo to `~/.config/devbox/.private/` on the host. Local paths are symlinked (zero-copy); git repos use shallow clone.

2. **Image build** (optional, cached) — if `.private/Dockerfile` exists, `container_build()` runs `docker build -f .private/Dockerfile -t devbox-agent:latest .private/`. This layers heavy installs (nvim plugins, LSPs) on top of the base image. Docker build cache means plugins only reinstall when lock files change.

3. **Startup overlay** — `entrypoint.sh` copies configs from the read-only mount (`/devbox/.private/`) into the user's home. This runs every start, so config file changes take effect immediately without rebuilding. Tmux configs are symlinked for version compatibility. The `.zshrc` replaces the default.

### Design rationale

- **Read-only mount + copy** — the host directory is mounted `:ro` so the container cannot modify host state. Configs are copied to user home for tools that need write access.
- **Build cache for plugins** — nvim Lazy sync, LSP installs, and similar heavy operations are baked into the image layer. Only re-runs when the relevant COPY layer changes (e.g., lazy-lock.json).
- **Overlay on every start** — even with pre-built images, the entrypoint re-copies configs. This means editing a config file takes effect on next `devbox start` without rebuilding.
- **Private repo isolation** — the repo is cloned to `~/.config/devbox/.private/`, never referenced in the public devbox repo or committed to images by default.

---

## Repository Layout

```
devbox/
├── devbox                      # Main CLI entry point (bash)
├── main.sh                     # Bootstrap / symlink installer
├── Dockerfile                  # Agent container image
├── entrypoint.sh               # Agent container entrypoint
├── docker-compose.yml          # Container + sidecar stack
├── proxy/
│   ├── Dockerfile              # mitmproxy sidecar image
│   ├── entrypoint.sh           # Proxy entrypoint (CA + mitmproxy)
│   ├── enforcer.py             # Domain allowlist addon
│   ├── logger.py               # SQLite logging addon
│   └── policy.yml.example      # Default policy template (reference)
├── lib/
│   ├── commands.sh             # CLI command handlers and helpers
│   ├── container.sh            # Container lifecycle functions
│   ├── firewall.sh             # iptables + ip6tables setup
│   ├── profile.sh              # Profile management
│   ├── allowlist.sh            # Allowlist CLI
│   └── ui.sh                   # TUI helpers, menus
├── tooling/
│   ├── completions.bash        # Bash tab completion
│   ├── completions.zsh         # Zsh tab completion
│   └── profiles/               # Language/tool profile definitions
│       ├── rust.sh
│       ├── python.sh
│       ├── node.sh
│       └── go.sh
├── config/
│   └── opencode/               # Default OpenCode config (available in container)
│       ├── opencode.json
│       ├── agents/
│       ├── pal/systemprompts/clink/
│       └── skills/
├── templates/
│   ├── policy.yml              # Default network policy
│   ├── AGENTS.md               # Per-project agent docs template
│   ├── zshrc                   # Container zsh config
│   ├── tmux.conf               # Container tmux config
│   └── private-overlay.Dockerfile  # Template for private config Dockerfile
├── docs/
│   ├── DESIGN.md               # This file
│   ├── PLAN.md                 # Implementation plan
├── .github/workflows/ci.yml    # CI: lint, build, smoke test
├── CREDITS.md
├── LICENSE
└── README.md
```

Host directories:

```
~/.devbox/                      # Per-user runtime data
├── secrets/.env                # API keys (created with umask 077)
├── <project-hash>/
│   ├── history/                # Shell history
│   ├── memory/                 # Agent memory persistence
│   ├── policy.yml              # Project network policy
│   └── logs/
│       └── api.db              # SQLite API log

~/.config/devbox/               # Global config (host-mounted ro)
├── opencode/                   # OpenCode config directory
│   ├── opencode.json
│   ├── agents/
│   ├── pal/systemprompts/clink/
│   └── skills/
└── .private/                   # Private config overlay (from git)
    ├── Dockerfile              # Optional private image layer
    ├── claude/                 # → ~/.claude/
    ├── opencode/               # → ~/.config/opencode/
    ├── nvim/                   # → ~/.config/nvim/
    ├── tmux/                   # → ~/.config/tmux/ + ~/.tmux.conf
    └── .zshrc                  # → ~/.zshrc
```

---

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| New project vs fork | New project | Scope of changes makes it genuinely distinct |
| Licensing | MIT | Compatible with all source projects |
| Container model | Isolated environment (exec-in) | Tool-agnostic; user runs whatever they want per-pane |
| Network enforcement | Dual-layer (mitmproxy + iptables) | Single-layer iptables bypassable via hardcoded IPs |
| Observability | SQLite + CLI queries | Zero extra infrastructure, queryable, persistent |
| Config storage | Host-mounted read-only | Updates without rebuilds; agent cannot tamper |
| Secrets | `--env-file` at runtime | Never baked into image |
| Container scope | One per project | True isolation, per-project network policy |
| Private configs | Git repo + optional Dockerfile overlay | Configs stay private; heavy installs baked into image |
| Credential injection | Environment only | No SSH key copying |
| Policy file location | Host-mounted read-only | Agent cannot modify its own network policy |
| Rate limiting | Intentionally not implemented | Single-user tool; user controls agent and API keys. Rate limiting adds config complexity and risks interrupting legitimate sessions. For runaway spend, set budget alerts on your API provider's dashboard. |
