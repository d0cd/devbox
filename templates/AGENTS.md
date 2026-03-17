# AGENTS.md — devbox Agent Configuration

This project runs inside a devbox container with the following agent capabilities.

## Primary Agent

- **Interface:** OpenCode
- **Model:** OpenRouter (claude-sonnet-4-5 default, with automatic failover)
- **Context:** Direct access to `/workspace` (this project directory)

## Available Subagents (via PAL MCP + clink)

| Agent | Best For | Context Window |
|-------|----------|----------------|
| Gemini CLI | Large file analysis, log review | 1M tokens |
| Codex CLI | Isolated code review, security audit | Standard |
| Claude Code | Specialist tasks, complex reasoning | Standard |
| PAL consensus | Multi-model architectural decisions | Multi-model |

## Dispatch Guidelines

- **Quick analysis** → use directly (no dispatch overhead)
- **Full codebase review** → dispatch to Gemini CLI (1M context)
- **Security audit** → dispatch to Codex (isolated, no side effects)
- **Architecture decisions** → use PAL consensus (multi-model cross-check)
- **Complex debugging** → dispatch to Codex (fresh context, strong reasoning)

## Safety Rules

1. Never run `git commit`, `git push`, `git reset --hard`, or `cargo publish` without explicit user confirmation.
2. Before any destructive file operation, state what will be changed and wait for approval.
3. Use clink to dispatch heavy tasks to preserve main session context.
4. All network traffic is logged and restricted to the domain allowlist.

## Network Policy

This container can only reach domains listed in the project's `policy.yml`.
All API calls are logged to SQLite and queryable via `devbox logs`.
