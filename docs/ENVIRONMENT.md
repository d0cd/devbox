# Environment Variables

All environment variables used by devbox.

## Host-Side (set by user or devbox CLI)

| Variable | Default | Description |
|---|---|---|
| `DEVBOX_DATA` | `~/.devbox` | Per-project data (auth, logs, history, memory) |
| `DEVBOX_CONFIG` | `~/.config/devbox` | Global config (OpenCode, PAL, private overlay) |
| `DEVBOX_PRIVATE_CONFIGS` | *(unset)* | Git URL for private config repo (claude/, opencode/, nvim/ dirs) |

## Injected into Container (via docker-compose.yml)

| Variable | Value | Description |
|---|---|---|
| `HTTP_PROXY` / `HTTPS_PROXY` | `http://proxy:8080` | Route all traffic through mitmproxy |
| `NO_PROXY` / `no_proxy` | `localhost,127.0.0.1,proxy` | Bypass proxy for local and sidecar connections |
| `NODE_EXTRA_CA_CERTS` | `/usr/local/share/ca-certificates/mitmproxy-ca.crt` | mitmproxy CA for Node.js |

## Secrets (via `~/.devbox/secrets/.env`)

| Variable | Description |
|---|---|
| `ANTHROPIC_API_KEY` | Anthropic API key (pay-per-token via Console) |
| `ANTHROPIC_AUTH_TOKEN` | Bearer token for LLM gateways/proxies (not for subscription auth) |
| `GH_TOKEN` | GitHub token (auto-injected from host `gh` CLI if available) |
| `OPENROUTER_API_KEY` | OpenRouter API key |
| `GEMINI_API_KEY` | Google Gemini API key |
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
| `DEVBOX_POLICY_FILE` | Path to project's policy.yml |
| `DEVBOX_LOG_DIR` | Path to project's log directory |
| `DEVBOX_MEMORY_DIR` | Path to project's memory directory |
| `DEVBOX_SECRETS_FILE` | Path to secrets .env file |
