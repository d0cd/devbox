#!/usr/bin/env bash
# Secrets management for devbox.
#
# Manages API keys and credentials injected into containers at runtime.
# Secrets are never baked into Docker images.
set -euo pipefail

cmd_secrets() {
    # Parse args: --project can appear anywhere before positional args.
    local use_project=false
    local -a args=()
    for arg in "$@"; do
        if [ "$arg" = "--project" ]; then
            use_project=true
        else
            args+=("$arg")
        fi
    done
    local subcmd="${args[0]:-show}"

    local secrets_file
    if [ "$use_project" = true ]; then
        local project_path
        project_path="$(resolve_project_path)"
        local hash
        hash="$(project_hash "$project_path")"
        secrets_file="${DEVBOX_DATA}/${hash}/secrets/.env"
        if [ ! -f "$secrets_file" ]; then
            ui_error "No project secrets file found. Start a session first."
            return 1
        fi
    else
        secrets_file="${DEVBOX_DATA}/secrets/.env"
    fi

    case "$subcmd" in
        show | ls)
            local label="global"
            [ "$use_project" = true ] && label="project"
            ui_header "Secrets (${label})"
            ui_info "File: $secrets_file"
            echo ""
            if [ ! -f "$secrets_file" ]; then
                ui_info "No secrets file found."
                return 0
            fi
            # Show keys with masked values.
            while IFS= read -r line || [ -n "$line" ]; do
                [[ "$line" =~ ^[[:space:]]*$ ]] && continue
                [[ "$line" =~ ^[[:space:]]*# ]] && {
                    echo "  $line"
                    continue
                }
                local key="${line%%=*}"
                local value="${line#*=}"
                if [ -n "$value" ]; then
                    echo "  ${key}=****"
                else
                    echo "  ${key}="
                fi
            done <"$secrets_file"
            ;;
        set)
            local key="${args[1]:-}"
            local value="${args[2]:-}"
            if [ -z "$key" ] || [ -z "$value" ]; then
                ui_error "Usage: devbox secrets set [--project] KEY VALUE"
                return 1
            fi
            # Validate key format.
            if [[ ! "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
                ui_error "Invalid key: '$key' (must be uppercase with underscores)"
                return 1
            fi
            # Update existing key or append.
            if grep -q "^${key}=" "$secrets_file" 2>/dev/null; then
                local tmpfile
                tmpfile="$(mktemp)"
                trap 'rm -f "$tmpfile"' RETURN
                awk -v k="$key" -v v="$value" -F= '{
                    if ($1 == k) print k "=" v
                    else print $0
                }' "$secrets_file" >"$tmpfile"
                (umask 077 && mv "$tmpfile" "$secrets_file")
                trap - RETURN
                ui_info "Updated ${key} in secrets."
            else
                (umask 077 && echo "${key}=${value}" >>"$secrets_file")
                ui_info "Added ${key} to secrets."
            fi
            if [ "$use_project" = true ]; then
                ui_info "Restart the session for changes to take effect."
            else
                ui_info "Restart any running sessions for changes to take effect."
            fi
            ;;
        rm | remove)
            local key="${args[1]:-}"
            if [ -z "$key" ]; then
                ui_error "Usage: devbox secrets remove [--project] KEY"
                return 1
            fi
            if [[ ! "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
                ui_error "Invalid key: '$key' (must be uppercase with underscores)"
                return 1
            fi
            if ! grep -q "^${key}=" "$secrets_file" 2>/dev/null; then
                ui_info "Key '${key}' not found in secrets."
                return 0
            fi
            local tmpfile
            tmpfile="$(mktemp)"
            trap 'rm -f "$tmpfile"' RETURN
            grep -v "^${key}=" "$secrets_file" >"$tmpfile"
            (umask 077 && mv "$tmpfile" "$secrets_file")
            trap - RETURN
            ui_info "Removed ${key} from secrets."
            ;;
        edit)
            local editor="${EDITOR:-${VISUAL:-vi}}"
            ui_info "Opening ${secrets_file} in ${editor}..."
            "$editor" "$secrets_file"
            ;;
        path)
            echo "$secrets_file"
            ;;
        help | --help | -h)
            cat <<'SHELP'
Usage: devbox secrets [show|set|remove|edit|path] [--project]

Examples:
  devbox secrets                              Show global secrets (masked)
  devbox secrets set ANTHROPIC_API_KEY sk-... Set a global secret
  devbox secrets set --project KEY value      Set a per-project secret
  devbox secrets remove OPENAI_API_KEY        Remove a secret
  devbox secrets edit                         Open secrets in $EDITOR
  devbox secrets show --project               Show per-project secrets
  devbox secrets path                         Print secrets file path
SHELP
            ;;
        *)
            ui_error "Unknown secrets command: '$subcmd'"
            ui_info "Usage: devbox secrets [show|set|remove|edit|path] [--project]"
            return 1
            ;;
    esac
}
