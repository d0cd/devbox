#!/usr/bin/env bash
# Bash tab completion for devbox CLI.
#
# Install:
#   source <(devbox completions)
#   # Or copy to /etc/bash_completion.d/devbox

_devbox_completions() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    local commands="shell stop status info profile allowlist secrets logs clean rebuild update completions help version"

    case "$prev" in
        devbox)
            mapfile -t COMPREPLY < <(compgen -W "$commands" -- "$cur")
            mapfile -t -O "${#COMPREPLY[@]}" COMPREPLY < <(compgen -d -- "$cur")
            return
            ;;
        profile)
            if [ "${COMP_WORDS[1]}" = "profile" ]; then
                local profiles="list"
                local profile_dir
                profile_dir="$(cd "$(dirname "$(command -v devbox 2>/dev/null || echo /dev/null)")" 2>/dev/null && pwd)/tooling/profiles"
                if [ -d "$profile_dir" ]; then
                    local f
                    for f in "$profile_dir"/*.sh; do
                        [ -f "$f" ] && profiles="$profiles $(basename "$f" .sh)"
                    done
                fi
                mapfile -t COMPREPLY < <(compgen -W "$profiles" -- "$cur")
                return
            fi
            ;;
        allowlist)
            if [ "${COMP_WORDS[1]}" = "allowlist" ]; then
                mapfile -t COMPREPLY < <(compgen -W "show add remove rm reset" -- "$cur")
                return
            fi
            ;;
        secrets)
            if [ "${COMP_WORDS[1]}" = "secrets" ]; then
                mapfile -t COMPREPLY < <(compgen -W "show set remove rm edit path --project" -- "$cur")
                return
            fi
            ;;
        logs)
            if [ "${COMP_WORDS[1]}" = "logs" ]; then
                mapfile -t COMPREPLY < <(compgen -W "--errors --blocked --slow --hosts" -- "$cur")
                return
            fi
            ;;
        clean)
            if [ "${COMP_WORDS[1]}" = "clean" ]; then
                mapfile -t COMPREPLY < <(compgen -W "--all --project" -- "$cur")
                return
            fi
            ;;
        info)
            mapfile -t COMPREPLY < <(compgen -d -- "$cur")
            return
            ;;
    esac

    COMPREPLY=()
}

complete -F _devbox_completions devbox
