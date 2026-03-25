#!/usr/bin/env zsh
# Zsh tab completion for devbox CLI.
#
# Install:
#   source <(devbox completions)
#   # Or copy to a directory in $fpath

_devbox() {
    local -a commands
    commands=(
        'start:Start a new session (devbox start [path])'
        'resume:Shell into a running session (devbox resume [name])'
        'stop:Stop a session (devbox stop [name])'
        'status:Show running sessions'
        'info:Show container status and project info'
        'profile:Install a language profile'
        'allowlist:View or edit the network allowlist'
        'mount:Manage per-project volume mounts'
        'secrets:Manage API keys and secrets'
        'logs:Show recent API calls'
        'clean:Clean project data'
        'resize:Resize agent container resources'
        'rebuild:Rebuild container images'
        'update:Pull latest source and rebuild'
        'completions:Output shell completions'
        'help:Show help'
        'version:Show version'
    )

    local -a allowlist_cmds profile_cmds secrets_cmds logs_opts clean_opts

    case "$words[2]" in
        profile)
            profile_cmds=('list:List available profiles')
            local profile_dir="${DEVBOX_ROOT:-$HOME/.local/share/devbox}/tooling/profiles"
            if [ -d "$profile_dir" ]; then
                for f in "$profile_dir"/*.sh(N); do
                    local name="${f:t:r}"
                    profile_cmds+=("${name}:Install ${name} profile")
                done
            fi
            _describe 'profile' profile_cmds
            return
            ;;
        allowlist)
            allowlist_cmds=(
                'show:View the network allowlist'
                'add:Add a domain to the allowlist'
                'remove:Remove a domain from the allowlist'
                'rm:Remove a domain (alias)'
                'reset:Reset allowlist to defaults'
            )
            _describe 'subcommand' allowlist_cmds
            return
            ;;
        mount)
            mount_cmds=(
                'add:Add a volume mount (project host-path container-path)'
                'remove:Remove a mount by container path'
                'rm:Remove a mount (alias)'
                'list:List custom mounts'
            )
            _describe 'subcommand' mount_cmds
            return
            ;;
        secrets)
            secrets_cmds=(
                'show:Show secrets (values masked)'
                'set:Set a secret (KEY VALUE)'
                'remove:Remove a secret'
                'rm:Remove a secret (alias)'
                'edit:Open secrets in editor'
                'path:Print secrets file path'
                '--project:Operate on per-project secrets'
            )
            _describe 'subcommand' secrets_cmds
            return
            ;;
        logs)
            logs_opts=('--errors:Show recent 4xx/5xx responses' '--blocked:Show requests blocked by enforcer' '--slow:Show requests slower than 5s' '--hosts:Show request counts by host' '--since:Filter to requests after timestamp' '--until:Filter to requests before timestamp')
            _describe 'option' logs_opts
            return
            ;;
        clean)
            clean_opts=('--all:Clean all devbox data' '--project:Clean this project data')
            _describe 'option' clean_opts
            return
            ;;
        info)
            _files -/
            return
            ;;
    esac

    _describe 'command' commands
    _files -/
}

compdef _devbox devbox
