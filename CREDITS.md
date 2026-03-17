# Credits

devbox builds on work from three open-source projects:

- **claudebox** (RchGrav) — MIT License
  https://github.com/RchGrav/claudebox
  Source of the profile system, per-project container architecture,
  allowlist CLI, and DX patterns (zsh, tmux, powerline).

- **agent-sandbox** (mattolson) — MIT License
  https://github.com/mattolson/agent-sandbox
  Source of the dual-layer network enforcement architecture:
  mitmproxy sidecar + iptables. The enforcer.py addon and
  firewall patterns are derived from this project.

- **claude-container** (nezhar) — MIT License
  https://github.com/nezhar/claude-container
  Source of the API logging proxy pattern and SQLite
  observability approach.
