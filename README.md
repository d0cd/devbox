# devbox

Isolated, containerized development environment.

Each project runs in its own Docker container with strict network enforcement, full API observability, and all AI/dev tools pre-installed. The container is infrastructure — you exec into it to use claude, opencode, nvim, or any tool you want.

## Table of Contents

- [Features](#features)
- [Quick Start](#quick-start)
- [Workflow](#workflow)
- [Usage](#usage)
- [Secrets Management](#secrets-management)
- [Private Config Overlay](#private-config-overlay)
- [API Observability](#api-observability)
- [Per-Project Configuration](#per-project-configuration)
- [Security Model](#security-model)
- [Architecture](#architecture)
- [System Requirements](#system-requirements)
- [Troubleshooting](#troubleshooting)

## Features

- **Isolated containers** — one per project, no host filesystem access beyond the project directory
- **Dual-layer network enforcement** — iptables + mitmproxy ensures no unapproved egress
- **API observability** — every API call logged to SQLite, queryable via `devbox logs`
- **Tool-agnostic** — Claude Code, OpenCode, Gemini CLI, Codex, neovim — all available inside
- **Private config overlay** — bring your own configs from a private repo, optionally pre-built into the image
- **Language profiles** — one-command setup for Rust, Python, Node.js, Go

## Quick Start

```bash
# Install
git clone https://github.com/d0cd/devbox.git ~/.local/share/devbox
ln -sf ~/.local/share/devbox/devbox ~/.local/bin/devbox

# Configure credentials
devbox secrets set GIT_AUTHOR_NAME "Your Name"
devbox secrets set GIT_AUTHOR_EMAIL you@example.com

# Claude Code auth (choose one):
#   Option A: Claude Max/Pro subscription (recommended)
#   Run /login inside the container on first use. Auth persists across restarts.
#   Option B: API key (pay-per-token via Console)
devbox secrets set ANTHROPIC_API_KEY sk-ant-...

# GitHub auth (auto-detected if `gh` is installed, or set manually)
devbox secrets set GH_TOKEN ghp_...

# Optional: other AI tool keys
devbox secrets set OPENROUTER_API_KEY sk-or-...
devbox secrets set GEMINI_API_KEY AIza...
devbox secrets set OPENAI_API_KEY sk-...

# Enable tab completion
source <(devbox completions)

# Start a session (first run builds images — takes ~5-10 min)
cd ~/projects/my-app
devbox
```

## Workflow

The container is an isolated dev environment. Start it once, then exec in from multiple tmux panes:

```bash
devbox                    # First pane — starts environment + opens shell
devbox resume ralph       # Additional panes — shell into running "ralph" by name
```

Inside the container, run any tool directly:

```bash
claude                    # Claude Code session
opencode                  # OpenCode session (with PAL MCP dispatch)
nvim .                    # Neovim (if configured via private overlay)
gemini                    # Gemini CLI
codex                     # Codex CLI
```

All tools share the same firewall, proxy, API logging, and secrets.

## Usage

```bash
devbox [project-path]      # Start or resume environment (default: current dir)
devbox start [path]        # Explicitly start a new session
devbox resume [name]       # Shell into a running session by name
devbox stop [name]         # Stop a session
devbox status              # Show running sessions
devbox info                # Show container status and project info
devbox profile rust        # Install a language profile
devbox profile python ml   # Python profile with ML packages
devbox allowlist           # View the network allowlist
devbox allowlist add X     # Add domain X
devbox allowlist remove X  # Remove domain X (alias: rm)
devbox allowlist reset     # Reset allowlist to defaults
devbox mount add <proj> <host> <container>  # Add a volume mount
devbox mount add <proj> <host> <container>:ro  # Read-only mount
devbox mount list [proj]   # List custom mounts
devbox mount remove <proj> <container-path>  # Remove a mount
devbox secrets             # Show API keys (values masked)
devbox secrets set K V     # Set a secret
devbox secrets edit        # Open secrets in $EDITOR
devbox secrets remove K    # Remove a secret
devbox secrets path        # Print path to secrets file
devbox logs                # Show recent API calls
devbox logs --errors       # Show recent 4xx/5xx responses
devbox logs --blocked      # Show requests blocked by enforcer
devbox logs --slow         # Show requests slower than 5 seconds
devbox logs --hosts        # Show request counts by host
devbox logs --since 1h     # Show logs from the last hour
devbox logs --until 2025-01-01  # Show logs before a date
devbox resize 12G          # Resize to 12 GB RAM (restarts container)
devbox resize 16G 8        # Resize to 16 GB RAM and 8 CPUs
devbox clean               # Clean this project's data
devbox clean --all         # Clean all devbox data
devbox rebuild             # Rebuild container images
devbox update              # Pull latest source and rebuild
devbox completions         # Output shell completions
devbox --version           # Print devbox version
devbox help                # Show help and usage info
```

## Secrets Management

Credentials are managed via `devbox secrets`, never baked into images:

```bash
# Global secrets (shared across all projects)
devbox secrets set ANTHROPIC_AUTH_TOKEN <token>   # Claude Max/Pro (from `claude setup-token`)
devbox secrets set GH_TOKEN ghp_...               # GitHub (auto-detected from `gh` if installed)
devbox secrets show

# Per-project secrets (override global for one project)
cd ~/projects/my-app
devbox secrets set --project OPENROUTER_API_KEY sk-or-project-specific-...
devbox secrets show --project
```

Per-project secrets are layered on top of global secrets. If the same key exists in both, the per-project value takes precedence.

### Credential inheritance

devbox auto-detects host credentials where possible:

| Credential | How | Manual step? |
|---|---|---|
| Claude Code (Max/Pro) | Run `/login` inside container on first use | One-time per project (persisted) |
| GitHub (`GH_TOKEN`) | Auto-extracted from host `gh auth` at startup | None if `gh` is installed |
| Git identity | From `devbox secrets set GIT_AUTHOR_NAME/EMAIL` | One-time setup |
| Other AI keys | From `devbox secrets set` | One-time setup |

To start devbox without any API keys (for non-AI workflows): `DEVBOX_NO_SECRETS=1 devbox`

## Private Config Overlay

Replicate your local dev environment inside the container without committing configs to the public codebase. Point devbox at your dotfiles — either a local directory or a private git repo:

```bash
# Local directory (simplest — just point at your existing configs)
export DEVBOX_PRIVATE_CONFIGS=~/configs

# Or a private git repo (cloned automatically)
export DEVBOX_PRIVATE_CONFIGS=git@github.com:you/configs.git
```

### Repo structure

Structure your private repo to match the tools you use (all directories are optional):

```
your-configs/
├── Dockerfile       # Optional: pre-build nvim plugins into the cached image
├── claude/          # Claude Code config (settings.json, hooks, skills)
├── opencode/        # OpenCode config (opencode.json, agents, skills)
├── nvim/            # Neovim config (init.lua, lua/, lazy-lock.json)
├── tmux/            # Tmux config (tmux.conf, tmux.conf.local)
└── .zshrc           # Zsh config (replaces the default devbox zshrc)
```

A template Dockerfile is provided at `templates/private-overlay.Dockerfile` — copy it into your configs repo as `Dockerfile`.

### How it works

1. **Link or clone** — on `devbox start`, a local directory is symlinked (or a git repo is cloned) to `~/.config/devbox/.private/` on the host. This never touches the public devbox repo.

2. **Build** (optional) — if your repo contains a `Dockerfile`, `devbox rebuild` layers it on top of the base image. The build context is the **parent** of `.private/` (i.e., `~/.config/devbox/`), so COPY paths reference sibling directories directly:

    ```dockerfile
    FROM devbox-agent:latest
    # Install zsh theme/plugins (cached in image layer).
    RUN git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
            /home/devbox/.oh-my-zsh/custom/themes/powerlevel10k
    ```

    Config files (nvim, tmux, claude, zshrc) don't need to be baked in — they're overlaid at startup from the read-only mount.

3. **Startup overlay** — every `devbox start` copies configs from the read-only mount into the container's home, so edits to your configs repo take effect immediately (without rebuilding the image).

### Workflow

```bash
# First time setup
export DEVBOX_PRIVATE_CONFIGS=~/configs    # or a git URL
devbox rebuild          # builds base image + your overlay (cached)
devbox                  # starts container with your full config

# After editing configs
devbox                  # picks up config file changes at startup
devbox rebuild          # only needed to re-cache nvim plugins
```

### What gets mapped where

| Repo path | Container path | Notes |
|-----------|---------------|-------|
| `claude/` | `~/.claude/` | settings, hooks, skills, CLAUDE.md |
| `nvim/` | `~/.config/nvim/` | init.lua, lua/, lazy-lock.json |
| `tmux/` | `~/.config/tmux/` + `~/.tmux.conf` | symlinked for version compat |
| `opencode/` | `~/.config/opencode/` | merged with defaults |
| `.zshrc` | `~/.zshrc` | replaces the default devbox zshrc |

### Volume mounts

All host-side data is stored under `~/.devbox/<project-hash>/` and mounted into the containers:

| Host path | Container path | Purpose |
|-----------|---------------|---------|
| `~/projects/my-app/` | `/workspace` (rw) | Project source code |
| `~/.config/devbox/` | `/devbox` (ro) | OpenCode config, private overlay |
| `~/.devbox/<hash>/history/` | `/data/history` | Shell history (persists across restarts) |
| `~/.devbox/<hash>/memory/` | `~/.opencode-mem/project` | OpenCode project memory |
| `~/.devbox/<hash>/logs/` | `/data` (proxy) | API call logs (SQLite) |
| `~/.devbox/<hash>/policy.yml` | `/proxy/policy.yml` (ro, proxy) | Network allowlist |
| `~/.devbox/<hash>/secrets/.env` | env-file injection | Per-project secrets |
| `~/.devbox/secrets/.env` | env-file injection | Global secrets |

Docker-managed volumes (not on host filesystem):

| Volume | Container path | Purpose |
|--------|---------------|---------|
| `proxy-ca` | `/run/proxy-ca` (agent, ro) and `/ca` (proxy, rw) | Shared mitmproxy CA certificate |
| `devbox-shared-memory` | `~/.opencode-mem/shared` | Cross-project OpenCode memory |

## API Observability

Every API call made through the proxy is logged to a SQLite database:

- **Recent calls** — `devbox logs` shows the last 20 requests
- **Errors** — `devbox logs --errors` shows 4xx/5xx responses
- **Blocked** — `devbox logs --blocked` shows requests rejected by the enforcer
- **Slow requests** — `devbox logs --slow` shows requests over 5 seconds
- **By host** — `devbox logs --hosts` shows request counts grouped by host

## Per-Project Configuration

Place a `.devboxrc` file in your project directory to set defaults:

```bash
DEVBOX_MEMORY=12G
DEVBOX_CPUS=6
DEVBOX_BRIDGE_SUBNET=172.18.0.0/16
DEVBOX_RELOAD_INTERVAL=15
DEVBOX_PRIVATE_CONFIGS=git@github.com:you/devbox-private.git
```

Environment variables take precedence over `.devboxrc` values. Only whitelisted variables are accepted.

## Resource Tuning

The agent container defaults to 8 GB RAM and 4 CPUs. Adjust per-project or globally:

```bash
# Per-project (in .devboxrc)
DEVBOX_MEMORY=16G
DEVBOX_CPUS=8

# Or via environment variable for a single session
DEVBOX_MEMORY=4G devbox
```

`devbox status` shows current memory usage and warns when the agent exceeds 80% of its limit.

## Security Model

Three layers of defense:

1. **Filesystem** — only the project directory is mounted (rw). Config is read-only. No access to `~/.ssh`, `~/.aws`, or other projects.
2. **Network** — all outbound blocked by iptables except through the proxy sidecar. The proxy enforces a per-project domain allowlist. Dual-layer means even processes ignoring `HTTP_PROXY` are blocked.
3. **Credentials** — API keys injected via `--env-file` at runtime, never baked into images. All API calls logged to SQLite.

See [docs/DESIGN.md](docs/DESIGN.md) for the full architecture and honest threat model.

## Architecture

```
┌─────────────────────────────────────────┐
│  Agent Container (per-project)          │
│  claude / opencode / nvim / gemini      │
│  iptables: all outbound → DROP          │
│           except Docker bridge          │
└───────────────┬─────────────────────────┘
                │ HTTP_PROXY
┌───────────────▼─────────────────────────┐
│  Proxy Sidecar                          │
│  mitmproxy enforcer → allowlist check   │
│  logger → SQLite → devbox logs           │
└─────────────────────────────────────────┘
```

## System Requirements

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| Docker | 24.0+ with Compose v2 | Latest stable |
| OS | macOS 13+ / Linux (x86_64/arm64) | Ubuntu 22.04+, macOS 14+ |
| RAM | 8 GB | 16 GB |
| Disk | 5 GB (images + workspace) | 10 GB+ |

The agent container defaults to 8 GB RAM / 4 CPUs. Adjust with `DEVBOX_MEMORY` and `DEVBOX_CPUS` (see [Resource Tuning](#resource-tuning)).

**Expected times:**
- First build: 5–10 minutes (downloads base images + tools)
- Subsequent starts: ~5 seconds (images cached locally)
- Image size: ~2.5 GB (agent) + ~200 MB (proxy)

## Updating

```bash
devbox update             # pulls latest source and rebuilds images
```

Running sessions continue using old images until restarted. `devbox update` stashes local modifications and restores them if the pull fails.

## Uninstalling

```bash
# Stop all running sessions
devbox stop

# Remove container images
docker rmi devbox-agent:latest devbox-proxy:latest 2>/dev/null

# Remove runtime data (logs, history, secrets)
rm -rf ~/.devbox

# Remove config
rm -rf ~/.config/devbox

# Remove the installation
rm -rf ~/.local/share/devbox
rm -f ~/.local/bin/devbox
```

## Troubleshooting

1. **"Docker is not running"** — Start Docker Desktop or the Docker daemon (`sudo systemctl start docker`).
2. **"Firewall initialization failed"** — Update Docker Desktop to latest. Verify the container has `NET_ADMIN` capability.
3. **"Proxy CA cert not found"** — Run `devbox rebuild` to regenerate the shared CA volume.
4. **HTTPS certificate errors inside container** — Check that `/usr/local/share/ca-certificates/mitmproxy-ca.crt` exists. If not, restart the stack (`devbox stop && devbox`).
5. **"No API log found"** — Start a devbox session first to generate logs.
6. **Container won't start** — Run `docker compose -p devbox-<name>-<hash> logs` to inspect (find the name with `devbox status`).
7. **Profile install fails** — Run `devbox <name>` to shell into the container. Check network connectivity through the proxy.
8. **Requests fail to an allowed domain** — Verify the domain is in the allowlist (`devbox allowlist`). Check proxy logs. Ensure the proxy CA cert is installed (`ls /usr/local/share/ca-certificates/mitmproxy-ca.crt` inside the container).

## License

MIT — see [LICENSE](LICENSE)

## Credits

See [CREDITS.md](CREDITS.md) for attribution to the open-source projects that inspired devbox.
