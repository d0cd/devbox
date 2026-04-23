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

### System Overview

```
Host (macOS / Linux)
    │
    ├── devbox CLI (bash)           ← orchestration, secrets, allowlist
    │     │
    │     ├── Docker Compose
    │     │     │
    │     │     ▼
    │     │   ┌─────────────────────────────────────────────────┐
    │     │   │  sandbox network (internal: true)               │
    │     │   │                                                 │
    │     │   │  ┌───────────────────────────────────────────┐  │
    │     │   │  │ Agent Container (per-project)             │  │
    │     │   │  │                                           │  │
    │     │   │  │  Tools: claude, opencode, nvim, gemini,   │  │
    │     │   │  │         codex, gh, zsh, tmux              │  │
    │     │   │  │                                           │  │
    │     │   │  │  iptables: OUTPUT → DROP                  │  │
    │     │   │  │    except → bridge:8080 (proxy)           │  │
    │     │   │  │    except → 127.0.0.11:53 (DNS)           │  │
    │     │   │  │                                           │  │
    │     │   │  │  Mounts:                                  │  │
    │     │   │  │    /workspace ← project dir (rw)          │  │
    │     │   │  │    /devbox   ← global config (ro)         │  │
    │     │   │  └──────────────┬────────────────────────────┘  │
    │     │   │                 │ HTTP_PROXY / HTTPS_PROXY      │
    │     │   │                 ▼                               │
    │     │   │  ┌───────────────────────────────────────────┐  │
    │     │   │  │ Proxy Sidecar                             │  │
    │     │   │  │                                           │  │
    │     │   │  │  mitmproxy:8080                           │  │
    │     │   │  │    ├── enforcer.py (allowlist)             │  │
    │     │   │  │    ├── injector.py (credentials)           │  │
    │     │   │  │    ├── notifier.py (cmux)                  │  │
    │     │   │  │    └── logger.py   (SQLite)               │  │
    │     │   │  │                                           │  │
    │     │   │  │  Mounts:                                  │  │
    │     │   │  │    /proxy/policy.yml ← allowlist (ro)     │  │
    │     │   │  │    /data/api.db     ← API log (rw)        │  │
    │     │   │  └───────────────────────────────────────────┘  │
    │     │   │                 │                               │
    │     │   └─────────────────┼───────────────────────────────┘
    │     │                     │
    │     │   ┌─────────────────▼───────────────────────────────┐
    │     │   │  external network                               │
    │     │   │  (proxy only — internet access)                 │
    │     │   └─────────────────────────────────────────────────┘
    │     │
    │     └── devbox logs, devbox allowlist, devbox secrets
    │           ↕ direct host filesystem (SQLite, policy.yml, .env)
    │
    └── ~/.devbox/<hash>/        ← per-project data (logs, history, secrets)
        ~/.config/devbox/        ← global config (opencode, .private/)
```

### Two-Container Stack

Every project runs exactly two containers orchestrated by Docker Compose:

1. **Agent container** (`devbox-agent`) — Ubuntu 24.04 base with all dev tools. Lives exclusively on the `sandbox` network (`internal: true`), meaning it has **no route to the internet**. All outbound is further locked down by iptables. Users exec into this container via `devbox resume`.

2. **Proxy sidecar** (`devbox-proxy`) — Python 3.12-slim with mitmproxy. Bridges the `sandbox` and `external` networks — the sole egress path for the agent. Runs four chained addons: domain enforcement, credential injection, cmux notification, and request logging.

### Dual-Network Isolation

Docker Compose defines two networks:

- **`sandbox`** — `internal: true` bridge. Only the agent and proxy join. The `internal` flag means Docker does not create a gateway, so containers on this network literally cannot reach the internet even without iptables.
- **`external`** — standard bridge. Only the proxy joins. This gives the proxy (and only the proxy) internet access.

The agent container connects to `sandbox` only. The proxy connects to both. This is the foundation of the isolation model — even if iptables is somehow bypassed, Docker's network topology prevents direct egress.

### Container Runtime Model

The agent container is **not** ephemeral. It starts once per `devbox start`, holds itself open with `tail -f /dev/null`, and accepts multiple concurrent exec sessions. Users open shells with `devbox resume <name>` (which runs `docker compose exec agent gosu devbox zsh`). This "exec-in" model means:

- Multiple tmux panes can each `devbox resume <name>` into the same environment
- All tools share the same firewall, proxy, secrets, and filesystem
- The container persists until `devbox stop` — workspace state, installed packages, and shell history survive across shell sessions
- No port mapping, no SSH, no serve/attach complexity

---

## Docker Runtime Environment

### macOS: OrbStack Recommended

On macOS, **OrbStack** is the recommended Docker runtime over Docker Desktop. The key reason: OrbStack's Linux VM uses a shared filesystem that correctly handles Unix domain sockets, which Docker Desktop's VirtioFS/gRPC-FUSE layer does not.

This matters for devbox because tools like **cmux** (the Claude Code multiplexer) communicate via Unix sockets. When running under Docker Desktop, these sockets silently fail or hang because VirtioFS doesn't fully support `AF_UNIX` over the VM boundary. OrbStack uses a purpose-built filesystem layer that handles sockets natively, so cmux sessions work correctly inside devbox containers.

Additional OrbStack advantages:
- **Lower resource usage** — smaller memory footprint than Docker Desktop's VM
- **Faster startup** — containers launch in ~1s vs. 3-5s
- **Native `docker` CLI** — drop-in compatible, no wrapper shims
- **Rosetta x86 emulation** — transparent emulation for x86 images on Apple Silicon

If you encounter hanging or broken tool sessions inside devbox on macOS, switching from Docker Desktop to OrbStack is the first troubleshooting step.

### Linux

Standard Docker Engine (24.0+) with Compose v2 works without modifications. No VM layer means Unix sockets, iptables, and all kernel interfaces work natively.

---

## Security Architecture

### Layer 1 — Filesystem Isolation (Docker Mounts)

The project directory and a small set of state directories are mounted read-write. Everything else is read-only or ephemeral:

| Mount | Access | Purpose |
|-------|--------|---------|
| `/workspace` | `rw` | Project source code (bind-mount from host) |
| `/devbox` | `ro` | Global config — OpenCode config, private overlay |
| `/devbox/.private` | `ro` | Private config overlay |
| `/run/proxy-ca` | `ro` | Shared proxy CA certificate (Docker volume) |
| `/data/history` | `rw` | Persistent shell history |
| `/home/devbox/.claude` | `rw` | Claude Code state (credentials, conversations) |
| `/home/devbox/.opencode-mem/project` | `rw` | OpenCode project memory |
| `/home/devbox/.opencode-mem/shared` | `rw` | Shared OpenCode memory (Docker volume) |
| `/tmp` | `rw` (tmpfs) | Ephemeral temp, 256 MB limit |

No access to `~/.ssh`, `~/.aws`, `~/.config`, or any other host directory. The container cannot read or modify host state beyond the project and the state mounts listed above.

### Layer 2 — Network Enforcement (Dual-Layer)

Two independent mechanisms block unauthorized egress:

#### 2a. iptables (kernel-level)

The agent container's entrypoint initializes iptables before any user code runs. All three chains are locked down:

```
INPUT chain:   DROP (default deny inbound)
  1. lo              — loopback
  2. ESTABLISHED     — responses to outbound connections

FORWARD chain: DROP (prevents use as network gateway)

OUTPUT chain:  DROP (default deny outbound)
  1. lo              — loopback (localhost)
  2. ESTABLISHED     — responses to accepted connections
  3. bridge:8080     — proxy sidecar (the only egress path)
  4. 127.0.0.11:53   — Docker's embedded DNS resolver (UDP + TCP)
  5. ICMP → DROP     — blocks covert channels and network reconnaissance

IPv6: all chains DROP (fail-closed — if ip6tables setup fails, firewall_init fails)
```

Rule order matters — loopback first (tools need localhost), then conntrack for performance, then the proxy exception, then DNS. ICMP is explicitly dropped last (it would be caught by the default DROP policy, but explicit rules are self-documenting and survive policy changes). The bridge subnet is auto-detected from `ip route` at container startup and validated against a strict CIDR pattern with octet range checking.

INPUT DROP prevents external connections from reaching services inside the container if network configuration is ever misconfigured. FORWARD DROP prevents the container from being used as a network gateway. These are defense-in-depth — the `internal: true` network should prevent both scenarios, but firewall rules survive Docker bugs.

iptables runs as root during Phase 1 of the entrypoint, before dropping to the unprivileged `devbox` user. The `NET_ADMIN` capability is required for this — it's the only elevated capability the container has (all others are dropped via `cap_drop: ALL`).

**IPv6 fail-closed:** If `ip6tables -P OUTPUT DROP` fails, `firewall_init` returns non-zero and the container refuses to start. Earlier versions silently continued with partial enforcement — this was changed to prevent IPv6 bypass.

**Health check:** The agent's Docker health check verifies the iptables DNS rule exists (`iptables -C OUTPUT -d 127.0.0.11 -p udp --dport 53 -j ACCEPT`). If iptables isn't active, the container reports unhealthy. Note: `iptables -C` requires `NET_ADMIN`. The health check runs via `docker exec` (not as a child of the entrypoint), so it gets the container's original capability set — unaffected by the `setpriv` bounding set drop in the main process tree.

#### 2b. mitmproxy (application-level)

The proxy sidecar runs `enforcer.py`, which intercepts every HTTP request and HTTPS CONNECT tunnel:

1. Reads the allowlist from `/proxy/policy.yml` (YAML format)
2. For each request, checks if `flow.request.pretty_host` (and optionally port) matches any allowed entry
3. Entry syntax:
   - `api.github.com` — hostname, any port
   - `host.docker.internal:11434` — hostname, specific port only
   - `*.github.com` — wildcard, any port (exact match too — matches `github.com` itself)
   - `*.github.com:443` — wildcard, specific port only
   - `[::1]:8080` — bracketed IPv6 with port
4. Non-matching requests get a `403 Forbidden` with body: `BLOCKED by devbox enforcer: <host>:<port> is not in the allowlist`

The proxy CA certificate is generated on first run. The private key is persisted on a proxy-only volume (`proxy-ca-keypair`), while only the public certificate is shared with the agent via a separate volume (`proxy-ca-cert`, mounted read-only). The agent entrypoint installs this certificate into the system trust store. This gives mitmproxy full HTTPS visibility — it can inspect, log, and enforce even for TLS traffic — without exposing the CA private key to the agent.

**Policy hot-reload:** The enforcer checks the policy file's mtime every `DEVBOX_RELOAD_INTERVAL` seconds (default: 30). When `devbox allowlist add` modifies the file on the host, the proxy picks up the change without restart.

#### Dual-layer guarantee

| Process behavior | Stopped by |
|-----------------|------------|
| Respects `HTTP_PROXY` env | Proxy enforcer |
| Ignores proxy, connects directly | iptables OUTPUT DROP |
| Attempts DNS to external resolver | iptables OUTPUT DROP (only 127.0.0.11 allowed) |
| Attempts ICMP covert channel | iptables ICMP DROP |
| Attempts IPv6 bypass | ip6tables OUTPUT DROP (fail-closed) |
| Listens for inbound connections | iptables INPUT DROP |
| Attempts network forwarding | iptables FORWARD DROP |
| Container escape (kernel exploit) | Defense-in-depth: `read_only` rootfs, `cap_drop: ALL`, NET_ADMIN dropped from bounding set after init. Keep Docker current. |

### Layer 3 — Credential Isolation

API keys are never baked into Docker images. They're injected at runtime via Docker Compose `env_file`:

```yaml
env_file:
  - ${DEVBOX_SECRETS_FILE}           # global secrets (~/.devbox/secrets/.env)
  - ${DEVBOX_PROJECT_SECRETS_FILE}   # per-project override
```

Secrets files are created with `umask 077` (mode 600). The CLI validates permissions and warns if they've been loosened. File locking (`flock`) prevents concurrent modification races.

#### Proxy-Layer Credential Injection

When API keys are present in the user's secrets files, devbox automatically activates proxy-layer credential injection:

1. Real API keys are passed only to the proxy sidecar (via `DEVBOX_INJECT_*` env vars)
2. The agent container receives phantom tokens (`sk-devbox-phantom-not-a-real-key`) that satisfy tool startup checks but have no real value
3. The proxy's `injector.py` addon strips any auth headers the agent sends and injects real credentials based on the destination domain

This means a compromised agent cannot exfiltrate API keys — it literally does not possess them. The provider-to-header mapping is hardcoded in the injector (not configurable by the agent), preventing credential routing to arbitrary domains.

**Supported providers:** Anthropic (`x-api-key`), OpenAI (`Authorization: Bearer`), Gemini (`x-goog-api-key`), OpenRouter (`Authorization: Bearer`), GitHub API (`Authorization: Bearer`).

**GH_TOKEN exception:** `GH_TOKEN` remains in the agent environment because git credential helpers need it client-side for HTTPS operations. The injector still handles `api.github.com` requests, but the token is also available to the agent. This is an accepted trade-off — git operations require the token, and `github.com` is already in the allowlist.

**Escape hatch:** Set `DEVBOX_CREDENTIAL_INJECTION=false` in the environment or `.devboxrc` to disable injection and pass real keys to the agent (pre-v0.4 behavior).

The logging proxy captures all outbound API request/response bodies. If a prompt injection tricks an agent into exfiltrating data in a request body, the log records it — visible via `devbox logs`.

### Container Hardening

```yaml
cap_drop: [ALL]                     # Drop all Linux capabilities
cap_add: [NET_ADMIN, SETUID, SETGID, SETPCAP]  # Firewall, gosu, cap drop
security_opt: [no-new-privileges:true]  # Prevent privilege escalation
read_only: true                      # Immutable root filesystem
tmpfs: /tmp (256MB)                  # Ephemeral temp, size-limited
pids: 4096                          # Prevent fork bombs (allows concurrent AI tools)
memory: 8G (configurable)           # OOM protection
cpus: 4.0 (configurable)            # CPU quota
restart: unless-stopped              # Auto-recover from crashes
```

`SETUID` and `SETGID` are required for `gosu` (the entrypoint drops from root to the `devbox` user after firewall setup). `SETPCAP` is required for `setpriv` to drop `NET_ADMIN` from the bounding set after firewall init. `no-new-privileges` prevents any process from gaining capabilities beyond what it was started with.

**Capability drop after init:** After `firewall_init()` completes, the entrypoint uses `setpriv --bounding-set -net_admin --inh-caps -net_admin` to irrevocably drop `NET_ADMIN` from the bounding set before switching to the unprivileged user. Once removed from the bounding set, no child process can ever regain `NET_ADMIN` — the kernel enforces this. The iptables rules become immutable from inside the container's main process tree.

### Mount Map and Permissions

| Container path | Host path | Mode | Purpose |
|---|---|---|---|
| `/workspace` | `~/projects/<name>` | **rw** | Project source code |
| `/devbox` | `~/.config/devbox` | ro | Global config, OpenCode |
| `/devbox/.private` | `~/configs/devbox` | ro | Private overlay (settings, hooks, skills) |
| `/data/history` | `~/.devbox/<hash>/history` | rw | Shell history |
| `/home/devbox/.claude` | `~/.devbox/claude` | **rw** | Claude Code state (credentials, conversations, plugins) |
| `/home/devbox/.opencode-mem/project` | `~/.devbox/<hash>/memory` | rw | OpenCode memory |
| `/home/devbox/.opencode-mem/shared` | Docker volume | rw | Shared OpenCode memory |
| `/run/proxy-ca` | Docker volume | ro | Proxy CA certificate |

Read-only rootfs (`read_only: true`) prevents persistence attacks — a compromised agent cannot modify system binaries, install backdoors, or tamper with the firewall scripts. Writable paths are constrained to tmpfs mounts and the bind mounts above.

### Honest Threat Model

| Threat | Mitigation | Residual risk |
|--------|-----------|---------------|
| Agent exfiltrates data | Dual-layer network + domain allowlist | Can still send to allowed domains |
| Prompt injection via project files | Network layer limits destinations; credentials not in agent env | In-boundary actions cannot be prevented |
| Credential theft (API keys) | Proxy-layer injection — agent gets phantom tokens, real keys never enter container | GH_TOKEN remains in agent for git operations |
| Claude OAuth token access | `~/.claude/.credentials.json` is rw — agent can read OAuth tokens | Accepted: agent already has API access via the proxy; the token grants no additional access beyond what the proxy allows |
| Malware persistence | `read_only: true` rootfs — system paths immutable | Agent can persist in writable mounts (`~/.claude/`, `/workspace`) |
| Git token over-scope | N/A — user responsibility | Token may grant access beyond mounted project |
| Container escape | `cap_drop: ALL`, `no-new-privileges`, NET_ADMIN dropped after init | Kernel exploits remain possible |
| Firewall modification | NET_ADMIN irrevocably dropped from bounding set after firewall init | `docker exec -u 0` retains container-level caps |
| DNS tunneling | DNS restricted to Docker resolver (127.0.0.11) | Docker resolver is trusted |
| IPv6 bypass | `ip6tables -P OUTPUT DROP` (fail-closed — container refuses to start on failure) | Requires ip6tables binary in container |
| Project file tampering | /workspace is rw by design — agent needs to edit code | Malicious commits, git hook injection possible |
| Claude hooks/settings tampering | `~/.claude/` is rw — agent can modify hooks | Private overlay re-applies settings on restart |

---

## Proxy Sidecar — Technical Details

### Addon Chain

mitmproxy loads four addons in order:

1. **`enforcer.py`** — Domain allowlist enforcement
2. **`injector.py`** — Proxy-layer credential injection (strip agent auth headers, inject real credentials)
3. **`notifier.py`** — cmux integration (sidebar status, notifications via host relay)
4. **`logger.py`** — SQLite request/response logging

All are loaded via `mitmdump -s enforcer.py -s injector.py -s notifier.py -s logger.py`. Order matters: the enforcer blocks disallowed domains before the injector touches headers (blocked flows never receive credentials). The logger runs last, recording the final state.

### enforcer.py

**Policy loading:** Reads `/proxy/policy.yml` using PyYAML's `safe_load`. Validates file size (max 1 MB), structure (`allowed` key must be a list), and wildcard patterns (only `*.` prefix allowed, no multi-wildcard). Returns empty list on any error — **fail-closed** design.

**Domain matching:** Case-insensitive. Two modes:
- Exact: `host == pattern`
- Wildcard: `*.example.com` matches `example.com` and `sub.example.com`

**Internal endpoints:** Requests to `/_devbox/*` paths are skipped by the enforcer — these are handled by the notifier addon for cmux integration and never leave the proxy.

**Blocking:** Both `request()` (HTTP) and `http_connect()` (HTTPS CONNECT) hooks check the allowlist. Blocked responses include the host (truncated to 253 chars to prevent oversized responses from malicious Host headers).

**Hot-reload:** The `_maybe_reload()` method, called on every request, checks if `RELOAD_INTERVAL` seconds have passed since the last mtime check. If the file's mtime changed, it reloads. This means `devbox allowlist add` takes effect within one interval without restarting the proxy.

### notifier.py — cmux Integration

The agent container cannot reach the host directly (internal-only network). cmux runs on the host and communicates via a Unix socket that can't bridge into containers. The notification system uses a multi-hop relay:

```
┌─────────────────────────────────────┐
│  Agent Container (sandbox network)  │
│                                     │
│  Claude Code fires hook             │
│       │                             │
│       │ stdin JSON                  │
│       ▼                             │
│  devbox-claude-hook <event>         │
│       │                             │
│       │ POST /_devbox/claude-hook   │
│       │ (HTTP via proxy env vars)   │
└───────┼─────────────────────────────┘
        │ sandbox network (internal)
┌───────▼─────────────────────────────┐
│  Proxy Sidecar (sandbox + external) │
│                                     │
│  notifier.py intercepts /_devbox/*  │
│       │                             │
│       │ TCP to host.docker.internal │
│       │ JSON-RPC: claude-hook.stop  │
└───────┼─────────────────────────────┘
        │ external network → host
┌───────▼─────────────────────────────┐
│  Host (macOS)                       │
│                                     │
│  cmux-proxy.py (TCP relay daemon)   │
│       │                             │
│       │ inline cmux socket protocol │
│       │ (set_status, notify_target, │
│       │  clear_notifications, etc.) │
│       ▼                             │
│  cmux app (Unix socket)             │
│  → sidebar status pills            │
│  → desktop notifications           │
│  → session tracking                │
└─────────────────────────────────────┘
```

**Why this chain:** Each hop crosses one isolation boundary. The agent can only reach the proxy (iptables). The proxy can reach the host (external network). The host daemon has cmux socket access. No firewall exceptions needed on the agent.

**What cmux handles:** All rendering — sidebar status pills ("Working", "Idle", "Needs input"), desktop notifications with Claude's actual response text, session tracking. The hooks pipe raw JSON from Claude Code; cmux interprets it natively via `cmux claude-hook`.

**Internal endpoints:** The notifier intercepts requests to `/_devbox/*` paths:
- `/_devbox/claude-hook` — forwards Claude Code hook JSON to the host proxy for cmux sidebar/notification updates
- `/_devbox/notify` — sends a notification via `notification.create` JSON-RPC
- `/_devbox/status` — sets sidebar status via text protocol

**Host-side proxy (`cmux-proxy.py`):** TCP relay started by `devbox` when cmux is detected. Listens on fixed port 19876, filters commands against an allowlist, and forwards to the cmux Unix socket. Claude Code hook events are handled inline using the cmux socket protocol (no subprocess calls). The socket connection is established at startup while the proxy is still in the cmux process tree (required for cmux's process-lineage auth). The proxy auto-restarts on the next devbox command if it dies.

**Workspace binding:** each devbox session's proxy sidecar is passed `CMUX_WORKSPACE_ID` at container start. `notifier.py` attaches this to every forwarded request and strips any agent-supplied `--tab=` / `--workspace=` / `params.workspace_id`. The host proxy treats the sidecar's value as authoritative — so sessions started in different cmux workspaces always route to the right workspace, regardless of which workspace the host daemon was first spawned from.

**Known limitation — local trust:** the host proxy binds `127.0.0.1:19876` with no authentication. Any process on the Mac can send commands that pass the allowlist (sidebar status, notifications, claude-hook events). The blast radius is limited to cmux sidebar/notification manipulation — no data exfiltration, no code execution, no container access. An attacker with local code execution has equivalent capabilities through native macOS APIs (`osascript`, `NSUserNotification`) without this proxy. A shared-secret token scheme would close this but adds compose plumbing; treated as a defense-in-depth follow-up.

### logger.py

**Database:** SQLite at `/data/api.db` with WAL mode for concurrent read/write. Schema:

```sql
CREATE TABLE requests (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
    method TEXT NOT NULL,
    url TEXT NOT NULL,
    host TEXT NOT NULL,
    status INTEGER,
    request_content_type TEXT,
    request_body TEXT,
    response_content_type TEXT,
    response_body TEXT,
    duration_ms INTEGER
);
```

**Body truncation:** Request and response bodies are truncated at 64 KB to prevent unbounded storage growth. Truncated entries are marked with `[TRUNCATED by devbox logger at 64KB]`.

**Retention:** Configurable via environment variables:
- `DEVBOX_LOG_MAX_AGE_DAYS` — delete rows older than N days (default: 90)
- `DEVBOX_LOG_MAX_ROWS` — keep at most N rows (default: 100,000)
- Pruning runs at startup and every 1,000 inserts

**Querying:** The host-side `devbox logs` command reads the SQLite database directly (or falls back to running `sqlite3` inside the container if the host lacks it). Supports filters: `--errors`, `--blocked`, `--slow`, `--hosts`, `--since`, `--until`.

### CA Certificate Flow

```
1. Proxy starts → generates CA keypair in /home/devbox/.mitmproxy/
   (flock serializes concurrent proxy starts on the same volume)
2. Exports mitmproxy-ca-cert.pem to /ca/ (shared Docker volume)
3. Agent entrypoint waits for /run/proxy-ca/mitmproxy-ca-cert.pem (up to 60s)
4. Copies to /usr/local/share/ca-certificates/mitmproxy-ca.crt
5. Runs update-ca-certificates --fresh
6. Sets NODE_EXTRA_CA_CERTS, REQUESTS_CA_BUNDLE, SSL_CERT_FILE
```

This ensures all TLS libraries (OpenSSL, Node.js, Python requests) trust the proxy's CA, allowing full HTTPS inspection.

---

## Agent Container — Technical Details

### Two-Phase Entrypoint

The agent container uses a split entrypoint to minimize privilege exposure:

**Phase 1 — Root (`entrypoint.sh`):**
- Detects the Docker bridge subnet from `ip route`
- Validates the CIDR (format regex + semantic octet/prefix range check)
- Sources and runs `firewall_init()` — mandatory, container refuses to start on failure
- Waits for proxy CA certificate, installs into system trust store
- Sets TLS environment variables

**Phase 2 — Unprivileged (`user-setup.sh` via `gosu devbox`):**
- Configures git identity from `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` env vars
- Links OpenCode configuration from read-only mount
- Copies private config overlay from `/devbox/.private/` into user home
- Sets up tmux symlinks for version compatibility
- Changes to `/workspace` and holds open with `tail -f /dev/null`

The `gosu` call (`exec gosu devbox ...`) replaces the root process entirely — no root shell remains running.

### Dockerfile — Multi-Stage Build

The agent image uses a two-stage Docker build:

**Stage 1 (builder):** Installs everything that requires build tools or network access:
- Node.js 22 LTS (via NodeSource apt repo)
- npm global packages: opencode-ai, @google/gemini-cli, @openai/codex, @anthropic-ai/claude-code, gsd-opencode
- GitHub CLI (via apt repo)
- uv (Python toolchain manager, copied from official image)
- Oh My Zsh + Powerlevel10k + plugins (git clones — least cacheable, ordered last)

**Stage 2 (runtime):** Copies only artifacts from the builder, installs minimal runtime packages:
- `COPY --from=builder` for npm packages, gh, uv, Oh My Zsh
- Runtime packages: bash, delta, fzf, git, gosu, iproute2, iptables, jq, neovim, python3, sqlite3, tmux, zsh
- Shell configs from `templates/`
- Firewall script and language profiles from `lib/` and `tooling/profiles/`
- Entrypoint scripts

Layer ordering is optimized for Docker build cache — apt packages and npm installs (stable) come before git clones (change frequently).

### Language Profiles

Profiles are self-contained bash scripts in `tooling/profiles/` that install language toolchains inside the running container:

| Profile | What it installs | Variants |
|---------|-----------------|----------|
| `rust` | rustup, cargo, clippy, rustfmt, cargo-watch, cargo-edit | `wasm` (wasm-pack, wasm32 target) |
| `python` | uv, python3, ruff, mypy, pytest | `ml` (numpy, pandas, scikit-learn), `api` (fastapi, httpx) |
| `node` | Node.js LTS, pnpm, typescript, eslint, prettier | `bun` (Bun runtime) |
| `go` | Go toolchain, golangci-lint, delve, gopls | — |

Profiles run via `docker compose exec agent gosu devbox bash -c 'source "/usr/local/lib/devbox/profiles/$1.sh"' _ "<name>"`. The profile name is validated against `^[a-zA-Z0-9_-]+$` before execution. Variants are validated against the profile's declared `# VARIANTS:` header.

---

## Network Policy

Each project gets its own `policy.yml`, stored at `~/.devbox/<hash>/policy.yml` on the host and mounted read-only into the proxy at `/proxy/policy.yml`. The agent container cannot access or modify this file.

The default policy (`templates/policy.yml`) allows:

- **Model APIs:** api.anthropic.com, openrouter.ai, generativelanguage.googleapis.com, api.openai.com
- **Package registries:** crates.io, registry.npmjs.org, pypi.org, files.pythonhosted.org, storage.googleapis.com
- **Code hosting:** github.com, api.github.com, *.githubusercontent.com
- **Language toolchains:** sh.rustup.rs, go.dev, dl.google.com, *.golang.org, astral.sh
- **Documentation:** docs.rs, docs.python.org, developer.mozilla.org
- **System updates:** security.ubuntu.com, archive.ubuntu.com

Users manage the allowlist via `devbox allowlist add|remove|reset`. All modifications use file locking (`flock`) to prevent concurrent write races.

---

## CLI Architecture

The `devbox` script is a bash CLI that sources library modules from `lib/`:

```
devbox (entry point)
  ├── lib/commands.sh    — command handlers (start, stop, profile, logs, etc.)
  ├── lib/container.sh   — Docker Compose lifecycle (build, start, shell, status)
  ├── lib/secrets.sh     — secrets management (set, show, edit, remove)
  ├── lib/allowlist.sh   — allowlist CRUD (add, remove, reset, show)
  ├── lib/mount.sh       — per-project volume mount management
  ├── lib/profile.sh     — profile discovery, validation, menus
  ├── lib/firewall.sh    — iptables rules (sourced inside container, not on host)
  └── lib/ui.sh          — TUI helpers (info, warn, error, confirm, spinner)
```

### Project Identity

Each project is identified by a 16-character SHA-256 hash of its absolute path:

```bash
echo -n "/home/user/projects/my-app" | sha256sum | cut -c1-16
# → a1b2c3d4e5f67890
```

This hash is used as the data directory name (`~/.devbox/bf341fbe16930634/`). The Docker Compose project name includes both the human-friendly name and the hash for uniqueness: `devbox-ralph-bf341fbe16930634`. The project name defaults to the directory basename but can be overridden via `DEVBOX_NAME` in `.devboxrc`. The full path is stored in `.project_path` and the name in `.project_name`.

### Per-Project Configuration (.devboxrc)

Projects can include a `.devboxrc` file with whitelisted variables:

| Variable | Type | Default | Purpose |
|----------|------|---------|---------|
| `DEVBOX_MEMORY` | Docker memory (e.g., `12G`) | `8G` | Agent container memory limit |
| `DEVBOX_CPUS` | Decimal (e.g., `4.0`) | `4.0` | Agent container CPU limit |
| `DEVBOX_BRIDGE_SUBNET` | CIDR (e.g., `172.18.0.0/16`) | Auto-detected | Docker bridge subnet for firewall |
| `DEVBOX_RELOAD_INTERVAL` | Integer (seconds) | `30` | Policy file hot-reload interval |
| `DEVBOX_PRIVATE_CONFIGS` | Git URL or path | — | Private config overlay source |
| `DEVBOX_NAME` | Alphanumeric + hyphens (max 32) | Directory basename | Human-friendly project name |

Only these variable names are accepted — arbitrary keys are rejected. Values are validated by type. Environment variables take precedence over file values.

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

### Three-Phase Flow

1. **Host sync** — `sync_private_configs()` symlinks a local directory or shallow-clones a git repo to `~/.config/devbox/.private/`. Local paths are symlinked (zero-copy); git repos use `--depth=1 --single-branch`.

2. **Image build** (optional, cached) — if `.private/Dockerfile` exists, `container_build()` runs `docker build -f .private/Dockerfile -t devbox-agent:latest`. This layers heavy installs (nvim plugins, LSP servers) on top of the base image. Docker build cache means plugins only reinstall when lock files change (e.g., `lazy-lock.json`).

3. **Startup overlay** — Phase 2 of the entrypoint (`user-setup.sh`) copies configs from the read-only mount (`/devbox/.private/`) into the user's home. This runs every start, so config file changes take effect immediately without rebuilding.

### Design Rationale

- **Read-only mount + copy** — the host directory is mounted `:ro` so the container cannot modify host state. Configs are copied into user home for tools that need write access (e.g., nvim's lazy-lock).
- **Build cache for plugins** — nvim Lazy sync, LSP installs, and similar heavy operations are baked into the image layer. Only re-runs when the relevant COPY layer changes.
- **Overlay on every start** — even with pre-built images, the entrypoint re-copies configs. Editing a config file takes effect on next `devbox start` without rebuilding.
- **Private repo isolation** — cloned to `~/.config/devbox/.private/`, never referenced in the public devbox repo or committed to images by default.

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

## Data Layout

### Host Filesystem

```
~/.devbox/                           # Per-user runtime data (DEVBOX_DATA)
├── secrets/.env                     # Global API keys (mode 600)
├── <project-hash>/
│   ├── .project_path                # Absolute path for display
│   ├── policy.yml                   # Project network policy
│   ├── secrets/.env                 # Per-project secrets override (mode 600)
│   ├── history/                     # Persistent shell history
│   ├── memory/                      # OpenCode project memory
│   └── logs/
│       └── api.db                   # SQLite API log

~/.config/devbox/                    # Global config (DEVBOX_CONFIG, mounted ro)
├── opencode/                        # OpenCode config (opencode.json, pal/, etc.)
└── .private/                        # Private config overlay (git or symlink)
    ├── Dockerfile                   # Optional image layer
    ├── claude/                      # → ~/.claude/
    ├── opencode/                    # → ~/.config/opencode/
    ├── nvim/                        # → ~/.config/nvim/
    ├── tmux/                        # → ~/.config/tmux/
    └── .zshrc                       # → ~/.zshrc
```

### Container Volume Mounts

| Host path | Container path | Mode | Purpose |
|-----------|---------------|------|---------|
| `~/projects/my-app/` | `/workspace` | rw | Project source |
| `~/.config/devbox/` | `/devbox` | ro | Config + private overlay |
| `~/.devbox/<hash>/history/` | `/data/history` | rw | Shell history |
| `~/.devbox/<hash>/memory/` | `~/.opencode-mem/project` | rw | OpenCode memory |
| `~/.devbox/<hash>/logs/` | `/data` (proxy) | rw | API logs |
| `~/.devbox/<hash>/policy.yml` | `/proxy/policy.yml` (proxy) | ro | Allowlist |
| `~/.devbox/<hash>/secrets/.env` | env-file | — | Per-project secrets |
| `~/.devbox/secrets/.env` | env-file | — | Global secrets |

Docker-managed volumes:

| Volume | Container path | Purpose |
|--------|---------------|---------|
| `proxy-ca-keypair` | `/ca` (proxy only, rw) | CA private key + cert (persists across restarts) |
| `proxy-ca-cert` | `/run/proxy-ca` (agent, ro) and `/ca-cert` (proxy, rw) | Public CA certificate only (shared with agent) |
| `devbox-shared-memory` | `~/.opencode-mem/shared` | Cross-project OpenCode memory |

---

## Repository Layout

```
devbox/
├── devbox                      # Main CLI entry point (bash)
├── main.sh                     # Bootstrap / symlink installer
├── Dockerfile                  # Agent container image (multi-stage)
├── entrypoint.sh               # Agent entrypoint (Phase 1: root, firewall + CA)
├── user-setup.sh               # Agent entrypoint (Phase 2: devbox user, config overlay)
├── docker-compose.yml          # Container + sidecar stack definition
├── proxy/
│   ├── Dockerfile              # Proxy sidecar image (Python 3.12-slim)
│   ├── entrypoint.sh           # Proxy entrypoint (CA gen + mitmdump)
│   ├── enforcer.py             # Domain allowlist addon
│   ├── injector.py             # Credential injection addon
│   ├── notifier.py             # cmux notification addon
│   └── logger.py               # SQLite logging addon
├── lib/
│   ├── commands.sh             # CLI command handlers and helpers
│   ├── container.sh            # Container lifecycle (build, start, shell, status)
│   ├── firewall.sh             # iptables + ip6tables setup
│   ├── mount.sh                # Volume mount management
│   ├── secrets.sh              # Secrets management (set/show/edit/remove)
│   ├── profile.sh              # Profile management and menus
│   ├── allowlist.sh            # Allowlist CRUD operations
│   └── ui.sh                   # TUI helpers (info, warn, error, confirm, spinner)
├── tooling/
│   ├── completions.bash        # Bash tab completion
│   ├── completions.zsh         # Zsh tab completion
│   └── profiles/
│       ├── _common.sh          # Shared profile helpers
│       ├── rust.sh             # Rust toolchain profile
│       ├── python.sh           # Python toolchain profile
│       ├── node.sh             # Node.js toolchain profile
│       └── go.sh               # Go toolchain profile
├── config/
│   └── opencode/               # Default OpenCode config
│       ├── opencode.json
│       ├── agents/
│       ├── pal/systemprompts/clink/
│       └── skills/
├── templates/
│   ├── policy.yml              # Default network policy
│   ├── claude-hooks.json       # Default Claude Code hooks/settings
│   ├── AGENTS.md               # Per-project agent docs template
│   ├── zshrc                   # Container zsh config
│   ├── tmux.conf               # Container tmux config
│   └── private-overlay.Dockerfile  # Template for private config Dockerfile
├── tests/
│   ├── bats/                   # Bash integration tests (BATS)
│   └── pytest/                 # Python unit tests (enforcer, logger)
├── docs/
│   ├── DESIGN.md               # This file
│   └── PLAN.md                 # Implementation plan and changelog
├── .github/workflows/ci.yml    # CI: lint + build + smoke test
├── .pre-commit-config.yaml     # Linter config (shellcheck, hadolint, ruff, etc.)
├── CREDITS.md                  # Attribution
├── LICENSE                     # MIT
└── README.md                   # Quickstart and user documentation
```

---

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| New project vs fork | New project | Scope of changes makes it genuinely distinct |
| Licensing | MIT | Compatible with all source projects |
| Container model | Isolated environment (exec-in) | Tool-agnostic; user runs whatever they want per-pane. No serve/attach complexity, no port mapping. |
| macOS runtime | OrbStack recommended | Docker Desktop's VirtioFS breaks Unix domain sockets (cmux). OrbStack handles them natively. |
| Network enforcement | Dual-layer (mitmproxy + iptables) | Single-layer iptables bypassable via hardcoded IPs. Single-layer proxy bypassable by ignoring env vars. Both together close the gap. |
| Network topology | `internal: true` + separate external | Even without iptables, Docker's network isolation prevents direct egress |
| Observability | SQLite + CLI queries | Zero extra infrastructure, queryable, persistent, works offline |
| Config storage | Host-mounted read-only | Updates without rebuilds; agent cannot tamper |
| Secrets | `--env-file` at runtime | Never baked into image. File locking prevents races. |
| Container scope | One per project | True isolation, per-project network policy |
| Private configs | Git repo + optional Dockerfile overlay | Configs stay private; heavy installs baked into cached image layer |
| Credential injection | Environment only | No SSH key copying, no volume-mounting credential files |
| Policy file location | Host-mounted read-only | Agent cannot modify its own network policy |
| Entrypoint split | Two phases (root → gosu devbox) | Minimizes root exposure. Phase 1: firewall + CA. Phase 2: user config + hold open. |
| IPv6 | DROP all if ip6tables available | Prevents bypass via IPv6 tunneling |
| DNS | Restricted to 127.0.0.11 | Prevents DNS tunneling to external resolvers |
| Rate limiting | Intentionally not implemented | Single-user tool; user controls agent and API keys. Rate limiting adds config complexity and risks interrupting legitimate sessions. For runaway spend, set budget alerts on your API provider's dashboard. |
| Fail-closed enforcer | Empty allowlist on policy error | Security default: if the policy file is missing or malformed, block all traffic rather than allow all |
| CIDR validation | Regex + semantic check | Regex validates format, separate function validates octets ≤ 255 and prefix ≤ 32 |
| Default seccomp | Docker's built-in profile | Blocks ~44 dangerous syscalls (ptrace, bpf, etc.) out of the box. Custom profile not needed given cap_drop: ALL. |
| Read-only rootfs | `read_only: true` | Root filesystem is immutable. Writable paths use tmpfs mounts (`/home/devbox`, `/tmp`, `/run`, `/var/log`, CA cert dirs). Oh My Zsh lives at `/opt/oh-my-zsh` on the read-only rootfs; user home is populated from `/etc/skel` at startup. |

---

## Comparison with Production Tools

devbox's architecture was evaluated against production AI isolation tools. Key comparisons:

| Tool | Isolation level | Network egress control | Request-level logging | Local/self-hosted |
|------|----------------|----------------------|----------------------|-------------------|
| **E2B** | Firecracker microVM (KVM) | SNI/Host header filtering | No | Cloud-first |
| **Daytona** | Docker (+ optional Kata) | API-driven allow/block | No | Yes |
| **Coder** | Process-level (nsjail/Landlock) | Domain + HTTP method + path | Audit logs only | Yes |
| **Gitpod** | K8s pods + VM | VPC network policies | No | Enterprise |
| **Dev Containers** | Docker container | None by default | No | Yes |
| **devbox** | Docker container | iptables + mitmproxy allowlist | Full HTTP req/resp to SQLite | Yes |

### Where devbox is ahead

**Request-level observability** — no other tool in this landscape logs full HTTP request/response bodies to a queryable store. Coder's Agent Boundaries come closest with audit logs, but at process level, not container level.

**Dual-layer network enforcement** — most tools use either iptables OR a proxy. devbox uses both, closing the gap that either alone leaves open (processes ignoring proxy env vs. hardcoded IPs bypassing iptables).

### Where production tools are ahead

**Isolation depth** — E2B and Firecracker use hardware virtualization (KVM), providing a fundamentally stronger boundary than Docker namespaces/cgroups. A container escape gives host access; a VM escape is orders of magnitude harder. gVisor sits in between as a potential drop-in upgrade.

**Credential brokering** — E2B's egressTransform injects Authorization headers at the proxy layer so secrets never enter the sandbox at all. Coder provisions per-workspace ephemeral credentials via Vault. devbox now uses a similar proxy-layer injection pattern (`injector.py`) for supported API providers, though `GH_TOKEN` remains in the agent environment for git credential helper compatibility.

**Read-only root filesystem** — production containers typically use `read_only: true` to prevent malware persistence. devbox now uses `read_only: true` with tmpfs mounts for writable paths and Oh My Zsh installed to `/opt/oh-my-zsh` on the read-only rootfs.

### Accepted trade-offs

These are deliberate design choices, not oversights:

1. **Docker over Firecracker** — devbox is a single-user local tool. Docker is universally available; Firecracker requires KVM and custom orchestration. The threat model is "prevent accidental data exfiltration by AI agents," not "multi-tenant hostile workloads."

2. **Proxy-layer credential injection with GH_TOKEN exception** — API keys for model providers (Anthropic, OpenAI, Gemini, OpenRouter) are injected at the proxy layer via `injector.py` — the agent receives phantom tokens. `GH_TOKEN` is the exception: git credential helpers need it client-side, so it remains in the agent environment. Disable injection entirely with `DEVBOX_CREDENTIAL_INJECTION=false`.

3. **SQLite over encrypted storage** — API logs contain request/response bodies (potentially sensitive). SQLite stores them in plaintext on the host. Encryption (SQLCipher) would add a dependency and key management complexity. For a single-user tool, host filesystem permissions (umask 077) are sufficient; the threat is agent exfiltration, not host compromise.
