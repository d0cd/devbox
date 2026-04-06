# Environment Variables

All environment variables used by devbox.

## Host-Side (set by user or devbox CLI)

| Variable | Default | Description |
|---|---|---|
| `DEVBOX_DATA` | `~/.devbox` | Per-project data (auth, logs, history, memory) |
| `DEVBOX_CONFIG` | `~/.config/devbox` | Global config (OpenCode, PAL, private overlay) |
| `DEVBOX_PRIVATE_CONFIGS` | *(unset)* | Git URL or local path for private config repo (claude/, opencode/, nvim/ dirs) |
| `DEVBOX_MEMORY` | `8G` | Agent container memory limit |
| `DEVBOX_CPUS` | `4.0` | Agent container CPU limit |
| `DEVBOX_BRIDGE_SUBNET` | *(auto-detected)* | Override Docker bridge subnet for firewall rules |
| `DEVBOX_RELOAD_INTERVAL` | `30` | Policy reload interval in seconds |
| `DEVBOX_NAME` | *(basename of project path)* | Override default project name |
| `DEVBOX_CREDENTIAL_INJECTION` | `true` | Enable/disable proxy credential injection |
| `DEVBOX_QUIET` | *(unset)* | Set to `1` for quiet mode (suppress info output) |
| `DEVBOX_NO_SECRETS` | *(unset)* | Set to `1` to start without API keys configured |

## Injected into Container (via docker-compose.yml)

| Variable | Value | Description |
|---|---|---|
| `HTTP_PROXY` / `HTTPS_PROXY` | `http://proxy:8080` | Route all traffic through mitmproxy |
| `NO_PROXY` / `no_proxy` | `localhost,127.0.0.1,proxy` | Bypass proxy for local and sidecar connections |
| `NODE_EXTRA_CA_CERTS` | `/usr/local/share/ca-certificates/mitmproxy-ca.crt` | mitmproxy CA for Node.js |
| `CLAUDE_CONFIG_DIR` | `/home/devbox/.claude` | Claude Code config directory |
| `DEVBOX_PROJECT` | `${DEVBOX_PROJECT_NAME:-workspace}` | Project name visible inside container |

## Secrets (via `~/.devbox/secrets/.env`)

| Variable | Description |
|---|---|
| `ANTHROPIC_API_KEY` | Anthropic API key (pay-per-token via Console) |
| `GH_TOKEN` | GitHub token (auto-injected from host `gh` CLI if available) |
| `OPENROUTER_API_KEY` | OpenRouter API key |
| `GEMINI_API_KEY` | Google Gemini API key |
| `GOOGLE_API_KEY` | Google API key (alias for `GEMINI_API_KEY` in credential injection) |
| `OPENAI_API_KEY` | OpenAI API key |
| `GIT_AUTHOR_NAME` | Git commit author name |
| `GIT_AUTHOR_EMAIL` | Git commit author email |

## Container-Internal (set by entrypoint.sh)

| Variable | Description |
|---|---|
| `DEVBOX_BRIDGE_SUBNET` | Detected Docker bridge subnet for firewall rules |
| `REQUESTS_CA_BUNDLE` | System CA bundle path for Python requests |
| `SSL_CERT_FILE` | System CA bundle path for general SSL |
| `EDITOR` / `VISUAL` | Set to `nvim` in container zshrc |

## Docker Compose Interpolation (set by container.sh)

| Variable | Description |
|---|---|
| `PROJECT_PATH` | Absolute path to the project directory |
| `PROJECT_HASH` | SHA256 hash prefix identifying the project |
| `DEVBOX_CONFIG` | Global config directory (`~/.config/devbox`) |
| `DEVBOX_PRIVATE_DIR` | Resolved private config overlay directory |
| `DEVBOX_POLICY_FILE` | Path to project's policy.yml |
| `DEVBOX_LOG_DIR` | Path to project's log directory |
| `DEVBOX_MEMORY_DIR` | Path to project's memory directory |
| `DEVBOX_HISTORY_DIR` | Path to project's shell history directory |
| `DEVBOX_SECRETS_FILE` | Path to global secrets .env file |
| `DEVBOX_PROJECT_SECRETS_FILE` | Path to per-project secrets .env file |
| `DEVBOX_PROXY_SECRETS_FILE` | Path to proxy-only credential injection .env |
| `DEVBOX_PHANTOM_FILE` | Path to agent phantom token overrides .env |
| `DEVBOX_CLAUDE_DIR` | Path to global Claude Code state directory |
| `DEVBOX_PROJECT_NAME` | Human-friendly project name |
| `DEVBOX_MEMORY` | Agent container memory limit (default: `8G`) |
| `DEVBOX_CPUS` | Agent container CPU limit (default: `4.0`) |
| `DEVBOX_CMUX_PROXY_PORT` | cmux filtering proxy port (empty if cmux unavailable) |
