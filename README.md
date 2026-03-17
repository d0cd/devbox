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

# Configure API keys
devbox secrets set ANTHROPIC_API_KEY sk-ant-...
devbox secrets set OPENROUTER_API_KEY sk-or-...
devbox secrets set GIT_AUTHOR_NAME "Your Name"
devbox secrets set GIT_AUTHOR_EMAIL you@example.com

# Enable tab completion
source <(devbox completions)

# Start a session
cd ~/projects/my-app
devbox
```

## Workflow

The container is an isolated dev environment. Start it once, then exec in from multiple tmux panes:

```bash
devbox                    # First pane — starts environment + opens shell
devbox shell              # Additional panes — shell into running env
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
devbox [project-path]      # Start environment (default: current directory)
devbox shell               # Open another shell into running environment
devbox stop                # Stop the container stack
devbox status              # Show running sessions
devbox info                # Show container status and project info
devbox profile rust        # Install a language profile
devbox profile python ml   # Python profile with ML packages
devbox allowlist           # View the network allowlist
devbox allowlist add X     # Add domain X
devbox allowlist remove X  # Remove domain X (alias: rm)
devbox allowlist reset     # Reset allowlist to defaults
devbox secrets             # Show API keys (values masked)
devbox secrets set K V     # Set a secret
devbox secrets edit        # Open secrets in $EDITOR
devbox logs                # Show recent API calls
devbox logs --errors       # Show recent 4xx/5xx responses
devbox logs --blocked      # Show requests blocked by enforcer
devbox logs --slow         # Show requests slower than 5 seconds
devbox logs --hosts        # Show request counts by host
devbox clean               # Clean this project's data
devbox clean --all         # Clean all devbox data
devbox rebuild             # Rebuild container images
devbox update              # Pull latest source and rebuild
devbox completions         # Output shell completions
devbox help                # Show help and usage info
```

## Secrets Management

API keys and credentials are managed via `devbox secrets`, never baked into images:

```bash
# Global secrets (shared across all projects)
devbox secrets set ANTHROPIC_API_KEY sk-ant-...
devbox secrets show

# Per-project secrets (override global for one project)
cd ~/projects/my-app
devbox secrets set --project OPENROUTER_API_KEY sk-or-project-specific-...
devbox secrets show --project
```

Per-project secrets are layered on top of global secrets. If the same key exists in both, the per-project value takes precedence.

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

2. **Build** (optional) — if your repo contains a `Dockerfile`, `devbox rebuild` layers it on top of the base image. This is where heavy installs like nvim plugins get cached:

    ```dockerfile
    FROM devbox-agent:latest
    COPY --chown=devbox:devbox nvim/ /home/devbox/.config/nvim/
    COPY --chown=devbox:devbox tmux/ /home/devbox/.config/tmux/
    COPY --chown=devbox:devbox .zshrc /home/devbox/.zshrc
    RUN gosu devbox nvim --headless "+Lazy! sync" +qa 2>/dev/null || true
    ```

    Docker caches each layer — plugins only reinstall when `lazy-lock.json` changes.

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
DEVBOX_BRIDGE_SUBNET=172.18.0.0/16
DEVBOX_RELOAD_INTERVAL=15
DEVBOX_PRIVATE_CONFIGS=git@github.com:you/devbox-private.git
```

Environment variables take precedence over `.devboxrc` values. Only whitelisted variables are accepted.

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

The agent container is allocated 8 GB RAM / 4 CPUs per `docker-compose.yml`.

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
4. **HTTPS certificate errors inside container** — Check that `/usr/local/share/ca-certificates/mitmproxy-ca-cert.pem` exists. If not, restart the stack (`devbox stop && devbox`).
5. **"No API log found"** — Start a devbox session first to generate logs.
6. **Container won't start** — Run `docker compose -p devbox-<hash> logs` to inspect.
7. **Profile install fails** — Run `devbox shell` to inspect the container. Check network connectivity through the proxy.
8. **Requests fail to an allowed domain** — Verify the domain is in the allowlist (`devbox allowlist`). Check proxy logs (`docker compose -p devbox-<hash> logs proxy`). Ensure the proxy CA cert is installed (`ls /usr/local/share/ca-certificates/mitmproxy-ca-cert.pem` inside the container).

## License

MIT — see [LICENSE](LICENSE)

## Credits

See [CREDITS.md](CREDITS.md) for attribution to the open-source projects that inspired devbox.
