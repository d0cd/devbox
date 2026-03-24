# devbox — Implementation Plan

> **Redesign note (v0.3):** Architecture shifted from "OpenCode-as-primary with serve/attach"
> to "isolated dev environment with exec-in model." The container holds open as infrastructure;
> users exec into it to run claude, opencode, nvim, or any tool. This simplified the CLI
> (removed attach, port management, OpenCode polling), the entrypoint, and the healthcheck.
> Private config overlay extended with optional Dockerfile for pre-building nvim/LSP configs.

## Phase 1: Core Container Stack

**Goal:** A working container with enforced network policy.

### 1.1 Proxy Sidecar

- [x] `proxy/Dockerfile` — Python 3.12-slim, mitmproxy, pyyaml
- [x] `proxy/enforcer.py` — mitmproxy addon that reads `policy.yml` and blocks non-allowed domains
- [x] `proxy/logger.py` — mitmproxy addon that logs all requests to SQLite
- [x] `templates/policy.yml` — default allowlist template

### 1.2 Agent Container

- [x] `Dockerfile` — Ubuntu 24.04 with Claude Code, OpenCode, Gemini CLI, Codex, GitHub CLI, neovim, zsh/tmux
- [x] `lib/firewall.sh` — iptables initialization (OUTPUT DROP, allow proxy + DNS only)
- [x] `entrypoint.sh` — firewall init, CA cert install, config overlay, hold container open

### 1.3 Docker Compose

- [x] `docker-compose.yml` — agent + proxy sidecar, internal bridge + external network
- [x] Health checks: agent (iptables policy DROP), proxy (socket check on 8080)

### 1.4 CLI — Minimum Viable

- [x] `devbox` / `devbox <path>` — start environment and drop into shell
- [x] `devbox shell` — exec into running container
- [x] `devbox stop` — stop container stack
- [x] `devbox info` — show container status and project path
- [x] `main.sh` — installer/symlinker

**Exit criteria:** `devbox ~/some-project` launches an isolated container. `curl https://evil.com` from inside fails. User can run `claude`, `opencode`, or `nvim` from the shell.

---

## Phase 2: UX and Profile System

- [x] `lib/profile.sh` — profile management (list, detect, menu, variants)
- [x] `tooling/profiles/` — rust, python, node, go profiles
- [x] `lib/allowlist.sh` — domain allowlist management (add, remove, reset)
- [x] Per-project isolation with `~/.devbox/<hash>/` structure
- [x] Shell environment: zsh + oh-my-zsh + powerlevel10k + tmux config

**Exit criteria:** `devbox profile rust` installs toolchain. `devbox allowlist add example.com` updates policy. Shell history persists.

---

## Phase 3: Observability

- [x] `logger.py` captures all proxy traffic to SQLite (WAL mode)
- [x] `devbox logs` CLI queries SQLite directly
- [x] `devbox logs` — recent calls, `--errors`, `--blocked`, `--slow`, `--hosts`

**Exit criteria:** `devbox logs` shows every API call with timing. Suspicious calls identifiable.

---

## Phase 4: Agent Layer

- [x] `config/opencode.json` — provider config, PAL MCP, rules
- [x] PAL MCP + clink subagent role prompts (codereview, security-audit, planner)
- [x] `templates/AGENTS.md` — dispatch guidelines
- [x] ~~Live verification of OpenRouter/Anthropic failover~~ (N/A — requires user API keys; verified manually)
- [x] ~~Live verification of clink dispatch~~ (N/A — requires user API keys; verified manually)

**Exit criteria:** From within OpenCode, user can dispatch a code review via clink.

---

## Phase 5: Polish and Distribution

- [x] `main.sh` installer, `devbox rebuild`, `devbox update`
- [x] `README.md`, `CREDITS.md`, `docs/DESIGN.md`
- [x] CI: shellcheck, ruff, hadolint, BATS tests, pytest, image build, smoke test

**Exit criteria:** `devbox` works on a fresh machine with only Docker installed.

---

## Phase 6: Security Audit Remediation

- [x] CIDR validation, git clone injection prevention, profile variant validation
- [x] CA cert pipeline fix, signal handling
- [x] Policy file size limit, YAML parse error handling, narrowed exceptions
- [x] Domain regex tightening, trap signals, port validation
- [x] Test fixes (mitmproxy dep, YAML wildcard)

**Exit criteria:** All tests pass. No regressions.

---

## Phase 7: Environment Redesign (v0.3)

**Goal:** Shift from OpenCode-as-primary to tool-agnostic isolated dev environment.

- [x] `entrypoint.sh` — replace `opencode serve` with `tail -f /dev/null` (hold container open)
- [x] `entrypoint.sh` — add nvim private config overlay support
- [x] `docker-compose.yml` — remove port 4096 exposure, healthcheck checks iptables policy
- [x] `Dockerfile` — remove EXPOSE 4096
- [x] `lib/container.sh` — remove `container_attach`, port validation, OpenCode polling; simplify `container_start` to start + wait + shell
- [x] `lib/commands.sh` — remove `cmd_attach`, `DEVBOX_OPENCODE_PORT`; update help text
- [x] `container_build()` — support private Dockerfile overlay (FROM devbox-agent:latest)
- [x] `devbox` CLI — remove attach command
- [x] Completions — remove attach from bash/zsh completions
- [x] Docs — update DESIGN.md, PLAN.md, README.md

**Exit criteria:** `devbox` starts environment. `devbox shell` (multiple panes) works. `claude`, `opencode`, `nvim` all run inside the container with full network isolation.

---

## Future Work

No outstanding items.

## Completed (this session)

- [x] **cmux notifications** — OSC 777 escape sequences written directly to the TTY from Claude Code hooks. No socket forwarding, no file relay — uses the existing terminal protocol chain (hook → TTY → docker exec → cmux). Based on approach from [manaflow-ai/cmux#833](https://github.com/manaflow-ai/cmux/issues/833). Requires devbox user in `tty` group.
- [x] **`devbox rebuild` without project context** — `container_build()` exports minimal defaults for compose variables needed at parse time.
- [x] **`devbox secrets set` missing mkdir** — `cmd_secrets()` creates global secrets directory on first access.
- [x] **Compose env var exports** — `_export_compose_env()` helper reconstructs all compose variables from a project hash. All commands (`shell`, `stop`, `profile`, `logs`, `resize`) now work in fresh shells.
- [x] **Two-phase entrypoint** — root phase (firewall + CA cert) then gosu to devbox phase (config overlay + hold open). No DAC_OVERRIDE/CHOWN capabilities needed.
- [x] **CA cert chain fix** — proxy persists both cert AND keypair on shared volume so restarts reuse the same CA. Agent appends cert to system bundle for curl/Python.
- [x] **Private config overlay** — `DEVBOX_PRIVATE_DIR` resolved from symlink, mounted directly into container. Private policy.yml used as default for new projects.
- [x] **Claude auth persistence** — `.credentials.json` saved/restored via dedicated bind mount.
- [x] **Disk usage display** — `devbox status` shows actual container disk usage via `docker ps -s`, not block I/O counters.
- [x] **Git credential helper** — `gh auth setup-git` configures gh as git credential helper when `GH_TOKEN` is available. Token auto-extracted from host's `gh` CLI at startup.

---

## Key Technical Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| mitmproxy CA cert injection complexity | Blocks HTTPS from agent | Test early; use `update-ca-certificates` in entrypoint |
| iptables requires `--cap-add NET_ADMIN` | Security trade-off | Document clearly; firewall runs at startup then drops caps |
| Large image size from all CLIs | Slow first build | Multi-stage build; layer ordering for cache efficiency |
| Docker Compose v2 vs v1 API differences | CLI incompatibility | Require Compose v2; check in installer |
| macOS bind mount performance | Filesystem event delays | VirtioFS mostly resolves; running nvim inside container eliminates it |
