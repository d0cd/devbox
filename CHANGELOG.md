# Changelog

All notable changes to devbox will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.0] - 2026-03-15

### Added
- `devbox status` command for quick container state overview
- `devbox logs` subcommands: `--errors`, `--blocked`, `--slow`, `--hosts`
- Interactive confirmation prompts for destructive operations (stop, clean, rebuild)
- Spinner feedback during container startup and profile installation
- Profile variant support (e.g., `devbox profile python ml`)
- Profile variant headers in profile scripts with structured metadata
- Version pinning for profile tool installations
- System requirements and troubleshooting sections in README
- Image security scanning with Trivy in CI
- CHANGELOG file
- CLI dispatch tests, container module tests, config validation tests
- Real firewall integration test running inside container with NET_ADMIN

### Changed
- `devbox help` now shows profile variant hints
- Profile menu displays variant annotations
- Profile variant validation errors on unknown variants instead of warning
- Upgraded profile tooling to use pinned major.minor versions

### Fixed
- Path disambiguation for `devbox <path>` when path could be mistaken for a command

### Security
- Rate limiting documented as intentional non-goal in DESIGN.md

## [0.1.0] - 2026-03-01

### Added
- Containerized per-project development environment with Docker Compose
- Dual-layer network enforcement: iptables + mitmproxy domain allowlist
- API observability via SQLite logging and `devbox logs` CLI
- OpenCode as primary interface with OpenRouter provider failover
- Multi-agent dispatch via PAL MCP + clink (Gemini CLI, Codex, Claude Code)
- Language profiles: Rust, Python (with ML variant), Node.js, Go
- Network allowlist management (`devbox allowlist add/rm/reset`)
- Per-project data isolation with stable path hashing
- API log viewer (`devbox logs`, `devbox logs --tail`)
- Shell environment with zsh, oh-my-zsh, powerlevel10k, tmux
- Installer script (`main.sh`) with dependency checking
- CI pipeline: shellcheck, shfmt, ruff, pytest, Docker image builds, smoke tests
- Security audit remediation: input validation, CIDR validation, policy size limits
- Proxy CA certificate pipeline for HTTPS inspection
- Private config overlay via `DEVBOX_PRIVATE_CONFIGS` git URL
