#!/usr/bin/env bash
# CLI command handlers and helpers for devbox.
#
# Sourced by the main devbox script. All functions expect DEVBOX_ROOT,
# DEVBOX_DATA, DEVBOX_CONFIG, and DEVBOX_VERSION to be set.
set -euo pipefail

# CIDR_PATTERN is defined in lib/firewall.sh and sourced by the main devbox script.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Load per-project .devboxrc configuration if it exists.
# Only whitelisted variable names are accepted to prevent injection.
_load_devboxrc() {
    local rc_file="${1:-.}/.devboxrc"
    [ -f "$rc_file" ] || return 0

    local allowed_vars="DEVBOX_BRIDGE_SUBNET DEVBOX_RELOAD_INTERVAL DEVBOX_PRIVATE_CONFIGS DEVBOX_MEMORY DEVBOX_CPUS"
    local line_num=0
    while IFS= read -r line || [ -n "$line" ]; do
        line_num=$((line_num + 1))
        # Skip blank lines and comments.
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # Must be KEY=VALUE format.
        if [[ ! "$line" =~ ^[A-Z_][A-Z0-9_]*= ]]; then
            ui_warn ".devboxrc:${line_num}: invalid syntax, skipping: ${line}"
            continue
        fi
        local key="${line%%=*}"
        local value="${line#*=}"
        # Only accept whitelisted variables.
        local found=false
        for allowed in $allowed_vars; do
            if [ "$key" = "$allowed" ]; then
                found=true
                break
            fi
        done
        if [ "$found" = false ]; then
            ui_warn ".devboxrc:${line_num}: unknown variable '${key}', skipping"
            continue
        fi
        # Validate values by type.
        case "$key" in
            DEVBOX_RELOAD_INTERVAL)
                if [[ ! "$value" =~ ^[0-9]+$ ]]; then
                    ui_warn ".devboxrc:${line_num}: '${key}' must be numeric, skipping"
                    continue
                fi
                ;;
            DEVBOX_BRIDGE_SUBNET)
                # CIDR_PATTERN is defined in lib/firewall.sh; inline it here to
                # avoid sourcing firewall.sh on the host (it references iptables).
                if [[ ! "$value" =~ $CIDR_PATTERN ]]; then
                    ui_warn ".devboxrc:${line_num}: '${key}' must be CIDR notation, skipping"
                    continue
                fi
                ;;
            DEVBOX_PRIVATE_CONFIGS)
                # Accept git URLs or local directory paths (absolute or ~/).
                local expanded_value="${value/#\~/$HOME}"
                if [[ ! "$value" =~ ^(https?://|git@|ssh://) ]] && [ ! -d "$expanded_value" ]; then
                    ui_warn ".devboxrc:${line_num}: '${key}' must be a git URL or existing directory, skipping"
                    continue
                fi
                ;;
            DEVBOX_MEMORY)
                # Docker memory notation: number + unit suffix (e.g., 4G, 512M).
                if [[ ! "$value" =~ ^[0-9]+[MmGg]$ ]]; then
                    ui_warn ".devboxrc:${line_num}: '${key}' must be a Docker memory value (e.g., 4G, 512M), skipping"
                    continue
                fi
                ;;
            DEVBOX_CPUS)
                # Decimal CPU count (e.g., 2, 4.0, 0.5).
                if [[ ! "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                    ui_warn ".devboxrc:${line_num}: '${key}' must be a CPU count (e.g., 2, 4.0), skipping"
                    continue
                fi
                ;;
        esac
        # Export only if not already set (env takes precedence over file).
        if [ -z "${!key:-}" ]; then
            export "$key=$value"
        fi
    done <"$rc_file"
}

# Compute a stable hash for a project path, used as a directory name.
# Uses sha256sum (Linux) or shasum (macOS), whichever is available.
project_hash() {
    local path="$1"
    if command -v sha256sum &>/dev/null; then
        echo -n "$path" | sha256sum | cut -c1-16
    elif command -v shasum &>/dev/null; then
        echo -n "$path" | shasum -a 256 | cut -c1-16
    else
        ui_error "Neither sha256sum nor shasum found. Cannot compute project hash."
        return 1
    fi
}

# Resolve the absolute canonical path for a project directory.
resolve_project_path() {
    local target="${1:-.}"
    if [ -d "$target" ]; then
        (cd "$target" && pwd)
    else
        ui_error "Project path does not exist: $target"
        return 1
    fi
}

# Get the policy file path for the current or specified project.
get_policy_file() {
    local project_path
    project_path="$(resolve_project_path "${1:-}")"
    local hash
    hash="$(project_hash "$project_path")"
    echo "${DEVBOX_DATA}/${hash}/policy.yml"
}

# Get the API log database path for the current project.
get_log_db() {
    local project_path
    project_path="$(resolve_project_path)"
    local hash
    hash="$(project_hash "$project_path")"
    local db="${DEVBOX_DATA}/${hash}/logs/api.db"
    if [ ! -f "$db" ]; then
        ui_error "No API log found at $db"
        ui_info "Start a devbox session first to generate logs."
        return 1
    fi
    echo "$db"
}

# Ensure per-project data directories exist.
ensure_project_dirs() {
    local hash="$1"
    local project_path="${2:-}"
    local project_dir="${DEVBOX_DATA}/${hash}"
    mkdir -p \
        "${project_dir}/history" \
        "${project_dir}/logs" \
        "${project_dir}/memory"
    (umask 077 && mkdir -p "${project_dir}/secrets")

    # Copy default policy if none exists for this project.
    # Restrictive permissions prevent other users from weakening the allowlist.
    if [ ! -f "${project_dir}/policy.yml" ]; then
        (umask 077 && cp "${DEVBOX_ROOT}/templates/policy.yml" "${project_dir}/policy.yml")
        ui_info "Created default network policy for project"
    fi

    # Create empty per-project secrets file if none exists.
    if [ ! -f "${project_dir}/secrets/.env" ]; then
        (
            umask 077
            cat >"${project_dir}/secrets/.env" <<'ENVEOF'
# Per-project secrets — override or supplement global secrets.
# This file is layered on top of ~/.devbox/secrets/.env.
# Set with: devbox secrets set --project KEY VALUE
ENVEOF
        )
    fi

    # Record the project path for later identification (e.g., devbox status).
    if [ -n "$project_path" ]; then
        echo "$project_path" >"${project_dir}/.project_path"
    fi
}

# Ensure global devbox directories exist.
ensure_global_dirs() {
    (umask 077 && mkdir -p "${DEVBOX_DATA}/secrets")
    mkdir -p "${DEVBOX_CONFIG}"

    # Create a placeholder secrets file if none exists.
    if [ ! -f "${DEVBOX_DATA}/secrets/.env" ]; then
        (
            umask 077
            cat >"${DEVBOX_DATA}/secrets/.env" <<'ENVEOF'
# devbox secrets — API keys injected at container runtime.
# This file is never committed or baked into images.
#
# ANTHROPIC_API_KEY=sk-ant-...
# OPENROUTER_API_KEY=sk-or-...
# GEMINI_API_KEY=AIza...
# OPENAI_API_KEY=sk-...
# GIT_AUTHOR_NAME=Your Name
# GIT_AUTHOR_EMAIL=you@example.com
ENVEOF
        )
        ui_warn "Created placeholder secrets file at ${DEVBOX_DATA}/secrets/.env"
        ui_warn "Edit it with your API keys before starting a session."
    else
        # Validate permissions on existing secrets file.
        local perms
        perms="$(stat -c '%a' "${DEVBOX_DATA}/secrets/.env" 2>/dev/null \
            || stat -f '%Lp' "${DEVBOX_DATA}/secrets/.env" 2>/dev/null)"
        case "$perms" in
            600 | 400) ;;
            *)
                ui_warn "Secrets file ${DEVBOX_DATA}/secrets/.env has permissions $perms (expected 600)."
                ui_warn "Run: chmod 600 ${DEVBOX_DATA}/secrets/.env"
                ;;
        esac
    fi

    # Deploy OpenCode config directory (includes opencode.json, pal/, skills/, agents/).
    if [ -d "${DEVBOX_ROOT}/config/opencode" ] && [ ! -d "${DEVBOX_CONFIG}/opencode" ]; then
        cp -r "${DEVBOX_ROOT}/config/opencode" "${DEVBOX_CONFIG}/opencode"
        ui_info "Deployed OpenCode configuration to ${DEVBOX_CONFIG}/opencode/"
    fi

    # Notify about private Dockerfile overlay if available.
    if [ -f "${DEVBOX_CONFIG}/.private/Dockerfile" ]; then
        ui_info "Private Dockerfile detected. Will apply overlay on next build."
    fi

    # Sync private configs if DEVBOX_PRIVATE_CONFIGS is set.
    if ! sync_private_configs; then
        ui_warn "Private config sync failed. Continuing without private configs."
    fi
}

# Sync private configs from a git repository or local directory.
# Set DEVBOX_PRIVATE_CONFIGS to:
#   - A git URL: git@github.com:user/configs.git (cloned to .private/)
#   - A local path: ~/configs (symlinked to .private/)
sync_private_configs() {
    local private_source="${DEVBOX_PRIVATE_CONFIGS:-}"
    local private_dir="${DEVBOX_CONFIG}/.private"
    [ -z "$private_source" ] && return 0

    # Expand ~ to $HOME (shell doesn't expand ~ in variable values).
    private_source="${private_source/#\~/$HOME}"

    # Local directory path — symlink instead of cloning.
    if [ -d "$private_source" ]; then
        local resolved
        resolved="$(cd "$private_source" && pwd)"
        if [ -L "$private_dir" ]; then
            # Already symlinked — verify it points to the right place.
            local current_target
            current_target="$(readlink "$private_dir")"
            if [ "$current_target" != "$resolved" ]; then
                rm -f "$private_dir"
                ln -sf "$resolved" "$private_dir"
                ui_info "Private configs re-linked to ${resolved}"
            fi
        elif [ -d "$private_dir" ]; then
            # Was previously a git clone — replace with symlink.
            ui_warn "Replacing cloned private configs with symlink to ${resolved}"
            rm -rf "$private_dir"
            ln -sf "$resolved" "$private_dir"
        else
            ln -sf "$resolved" "$private_dir"
            ui_info "Private configs linked to ${resolved}"
        fi
        return 0
    fi

    # Git URL — clone or pull.
    if [[ ! "$private_source" =~ ^(https?://|git@|ssh://) ]]; then
        ui_error "DEVBOX_PRIVATE_CONFIGS must be a git URL or local directory path."
        ui_error "Got: '$private_source'"
        return 1
    fi

    if [ -L "$private_dir" ]; then
        # Was previously a symlink — remove and clone fresh.
        rm -f "$private_dir"
    fi

    if [ -d "$private_dir/.git" ]; then
        if ! git -C "$private_dir" pull --ff-only 2>/dev/null; then
            ui_warn "Private config pull failed (branch may have diverged). Using cached copy."
        fi
    else
        ui_info "Cloning private configs..."
        git clone --depth=1 --single-branch -- "$private_source" "$private_dir"
    fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_start() {
    local project_path
    project_path="$(resolve_project_path "${1:-}")"
    local hash
    hash="$(project_hash "$project_path")"

    ensure_global_dirs
    ensure_project_dirs "$hash" "$project_path"

    ui_header "devbox v${DEVBOX_VERSION}"
    ui_info "Project: ${project_path/#$HOME/\~}"

    # Suggest profiles based on project files.
    local detected
    detected="$(profile_detect "$project_path")"
    if [ -n "$detected" ]; then
        local detected_list
        detected_list="$(echo "$detected" | tr '\n' ', ' | sed 's/, $//')"
        ui_info "Detected profiles: ${detected_list}. Install with: devbox profile <name>"
    fi

    container_start "$project_path" "$hash"
}

cmd_shell() {
    container_shell
}

cmd_stop() {
    # Show which session will be stopped for clarity.
    local project
    project="$(_require_single_project)" || return 1
    local project_label="$project"
    # Try to resolve the human-readable project path from stored data.
    local hash="${project#devbox-}"
    if [ -f "${DEVBOX_DATA}/${hash}/.project_path" ]; then
        project_label="$(cat "${DEVBOX_DATA}/${hash}/.project_path") ($project)"
    fi
    if ! ui_confirm "Stop session: ${project_label}?"; then
        ui_info "Cancelled."
        return 0
    fi
    docker compose -f "${DEVBOX_ROOT}/docker-compose.yml" -p "$project" down
    ui_info "Container stack stopped."
}

cmd_status() {
    container_status
}

cmd_info() {
    local project_path
    project_path="$(resolve_project_path "${1:-}")"
    local hash
    hash="$(project_hash "$project_path")"

    local path_label="${project_path/#$HOME/\~}"
    ui_header "devbox v${DEVBOX_VERSION} — info"
    ui_info "Project:    $path_label"
    ui_info "Project ID: $hash"
    ui_info "Data:       ${DEVBOX_DATA/#$HOME/\~}/${hash}"
    echo ""
    container_status
}

cmd_profile() {
    local name="${1:-}"
    local variant="${2:-}"

    if [ -z "$name" ]; then
        # No profile specified — show interactive menu (may return "name variant").
        local selection
        selection="$(profile_menu)" || return 1
        name="${selection%% *}"
        if [ "$selection" != "$name" ]; then
            variant="${selection#* }"
        fi
    fi

    if [ "$name" = "list" ]; then
        profile_list_detailed
        return 0
    fi

    # Validate profile name to prevent path traversal and injection.
    _validate_profile_name "$name" || return 1

    if [ -n "$variant" ] && [[ ! "$variant" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        ui_error "Invalid profile variant: '$variant'"
        return 1
    fi

    # Verify the profile exists locally before attempting container install.
    if [ ! -f "${DEVBOX_ROOT}/tooling/profiles/${name}.sh" ]; then
        ui_error "Unknown profile: $name"
        ui_info "Available profiles: $(profile_list | tr '\n' ' ')"
        return 1
    fi

    # Validate variant against declared variants for this profile.
    if [ -n "$variant" ]; then
        local declared_variants
        declared_variants="$(profile_variants "$name")"
        if [ -z "$declared_variants" ]; then
            ui_error "Profile '$name' does not support variants."
            return 1
        elif ! echo "$declared_variants" | grep -qxF "$variant"; then
            ui_error "Unknown variant '$variant' for profile '$name'."
            ui_info "Available variants: $(echo "$declared_variants" | tr '\n' ' ')"
            return 1
        fi
    fi

    # Execute profile inside running container using positional args (no injection).
    local project
    project="$(_require_single_project)"
    ui_info "Installing profile '$name' in running container..."

    ui_spinner "Installing profile '$name' (this may take several minutes)..." &
    local spinner_pid=$!
    trap 'kill $spinner_pid 2>/dev/null; wait $spinner_pid 2>/dev/null' RETURN

    local exec_output
    if ! exec_output="$(docker compose -p "$project" exec \
        -e PROFILE_VARIANT="$variant" \
        agent gosu devbox bash -c 'source "/usr/local/lib/devbox/profiles/$1.sh"' _ "$name" 2>&1)"; then
        kill $spinner_pid 2>/dev/null
        wait $spinner_pid 2>/dev/null
        trap - RETURN
        printf "\r"
        ui_error "Profile '$name' installation failed."
        if [ -n "$exec_output" ]; then
            echo "$exec_output" | tail -20 >&2
        fi
        ui_info "Run 'devbox shell' to inspect the container for errors."
        return 1
    fi

    kill $spinner_pid 2>/dev/null
    wait $spinner_pid 2>/dev/null
    trap - RETURN
    printf "\r"
    ui_info "Profile '$name' installed successfully."
}

cmd_allowlist() {
    local subcmd="${1:-}"
    shift 2>/dev/null || true
    local policy_file
    policy_file="$(get_policy_file)"

    case "$subcmd" in
        add)
            allowlist_add "$policy_file" "$@"
            ;;
        remove | rm)
            allowlist_remove "$policy_file" "${1:-}"
            ;;
        reset)
            allowlist_reset "$policy_file"
            ;;
        show | "")
            allowlist_show "$policy_file"
            ;;
        help | --help | -h)
            cat <<'AHELP'
Usage: devbox allowlist [show|add|remove|rm|reset]

Examples:
  devbox allowlist                    Show current allowlist
  devbox allowlist add example.com    Allow a specific domain
  devbox allowlist add *.github.com   Allow all subdomains
  devbox allowlist add a.com b.com    Add multiple domains at once
  devbox allowlist remove example.com Remove a domain
  devbox allowlist reset              Restore default allowlist
AHELP
            ;;
        *)
            ui_error "Unknown allowlist command: '$subcmd'"
            ui_info "Usage: devbox allowlist [show|add|remove|rm|reset]"
            return 1
            ;;
    esac
}

_sqlite3_query() {
    local db="$1" query="$2"
    if command -v sqlite3 &>/dev/null; then
        sqlite3 -header -column "$db" "$query"
    else
        # Fallback: run sqlite3 inside the running container (it has sqlite3).
        local project
        project="$(_require_single_project)" || return 1
        docker compose -p "$project" exec -T agent \
            sqlite3 -header -column /data/api.db "$query"
    fi
}

cmd_logs() {
    local db
    # Try host-side db path first; if sqlite3 is missing, we'll query inside the container.
    if command -v sqlite3 &>/dev/null; then
        db="$(get_log_db)" || return 1
    else
        # Verify the container is running (we'll query inside it).
        _require_single_project >/dev/null || return 1
        db="/data/api.db" # container-side path, used in query string only
    fi

    # Parse --since and --until from args.
    local since="" until=""
    local -a remaining=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --since)
                if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
                    ui_error "--since requires a timestamp argument"
                    return 1
                fi
                since="$2"
                shift 2
                ;;
            --until)
                if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
                    ui_error "--until requires a timestamp argument"
                    return 1
                fi
                until="$2"
                shift 2
                ;;
            *)
                remaining+=("$1")
                shift
                ;;
        esac
    done

    # Validate timestamp format to prevent SQL injection.
    # Accept ISO 8601 timestamps: YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS (with optional fractional seconds).
    local _ts_pattern='^[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?)?$'
    if [ -n "$since" ] && [[ ! "$since" =~ $_ts_pattern ]]; then
        ui_error "Invalid --since timestamp: '$since' (use YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS)"
        return 1
    fi
    if [ -n "$until" ] && [[ ! "$until" =~ $_ts_pattern ]]; then
        ui_error "Invalid --until timestamp: '$until' (use YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS)"
        return 1
    fi

    # Build time filter clause (values validated against strict pattern above).
    local time_clause=""
    if [ -n "$since" ]; then
        time_clause="${time_clause} AND timestamp >= '${since}'"
    fi
    if [ -n "$until" ]; then
        time_clause="${time_clause} AND timestamp <= '${until}'"
    fi

    case "${remaining[0]:-}" in
        --errors)
            _sqlite3_query "$db" \
                "SELECT timestamp, method, host, url, status, duration_ms FROM requests WHERE status >= 400${time_clause} ORDER BY id DESC LIMIT 50"
            ;;
        --blocked)
            _sqlite3_query "$db" \
                "SELECT timestamp, method, host, url FROM requests WHERE status = 403${time_clause} ORDER BY id DESC LIMIT 50"
            ;;
        --slow)
            _sqlite3_query "$db" \
                "SELECT timestamp, method, host, url, status, duration_ms FROM requests WHERE duration_ms > 5000${time_clause} ORDER BY duration_ms DESC LIMIT 50"
            ;;
        --hosts)
            _sqlite3_query "$db" \
                "SELECT host, COUNT(*) as requests, SUM(CASE WHEN status >= 400 THEN 1 ELSE 0 END) as errors, ROUND(AVG(duration_ms)) as avg_ms FROM requests WHERE 1=1${time_clause} GROUP BY host ORDER BY requests DESC"
            ;;
        *)
            ui_info "Recent API calls:"
            _sqlite3_query "$db" \
                "SELECT timestamp, method, host, status, duration_ms FROM requests WHERE 1=1${time_clause} ORDER BY id DESC LIMIT 20"
            ;;
    esac
}

cmd_clean() {
    local flag="${1:-}"

    case "$flag" in
        --all)
            # Validate DEVBOX_DATA before destructive rm -rf.
            if [ -z "${DEVBOX_DATA:-}" ] || [ "$DEVBOX_DATA" = "/" ] || [ "$DEVBOX_DATA" = "$HOME" ]; then
                ui_error "Refusing to delete: DEVBOX_DATA points to an unsafe path ('${DEVBOX_DATA:-}')"
                return 1
            fi
            ui_warn "This will delete ALL project data, logs, and API keys in ${DEVBOX_DATA}/"
            if ui_confirm "Delete all devbox data including secrets?"; then
                rm -rf "${DEVBOX_DATA}"
                ui_info "All devbox data removed."
            fi
            ;;
        --project | "")
            local project_path
            project_path="$(resolve_project_path)"
            local hash
            hash="$(project_hash "$project_path")"
            local project_dir="${DEVBOX_DATA}/${hash}"

            if [ ! -d "$project_dir" ]; then
                ui_info "No data found for this project."
                return 0
            fi

            if ui_confirm "Delete data for this project ($project_dir)?"; then
                rm -rf "$project_dir"
                ui_info "Project data removed."
            fi
            ;;
        *)
            ui_error "Unknown flag: $flag (use --project or --all)"
            return 1
            ;;
    esac
}

cmd_resize() {
    local memory="${1:-}"
    local cpus="${2:-}"

    if [ -z "$memory" ]; then
        ui_error "Usage: devbox resize <memory> [cpus]"
        ui_info "Examples:"
        ui_info "  devbox resize 12G       # 12 GB RAM, keep current CPUs"
        ui_info "  devbox resize 16G 8     # 16 GB RAM, 8 CPUs"
        ui_info "  devbox resize 4G 2      # 4 GB RAM, 2 CPUs"
        return 1
    fi

    # Validate memory format.
    if [[ ! "$memory" =~ ^[0-9]+[MmGg]$ ]]; then
        ui_error "Invalid memory value: '$memory' (use e.g., 4G, 512M)"
        return 1
    fi

    # Validate CPU format if provided.
    if [ -n "$cpus" ] && [[ ! "$cpus" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        ui_error "Invalid CPU value: '$cpus' (use e.g., 2, 4.0)"
        return 1
    fi

    export DEVBOX_MEMORY="$memory"
    # Preserve existing DEVBOX_CPUS if no CPU arg provided.
    if [ -n "$cpus" ]; then
        export DEVBOX_CPUS="$cpus"
    else
        export DEVBOX_CPUS="${DEVBOX_CPUS:-4.0}"
    fi

    local project
    project="$(_require_single_project)" || return 1
    local hash="${project#devbox-}"

    local cpus_label="$DEVBOX_CPUS"
    ui_info "Resizing to ${memory} RAM, ${cpus_label} CPUs..."
    ui_info "This restarts the container. Workspace and history are preserved."

    if ! ui_confirm "Restart with new resource limits?"; then
        ui_info "Cancelled."
        return 0
    fi

    # Re-export all compose variables so the stack can restart.
    local project_path=""
    if [ -f "${DEVBOX_DATA}/${hash}/.project_path" ]; then
        project_path="$(cat "${DEVBOX_DATA}/${hash}/.project_path")"
    fi

    export PROJECT_PATH="${project_path:-.}"
    export PROJECT_HASH="$hash"
    local project_dir="${DEVBOX_DATA}/${hash}"
    export DEVBOX_POLICY_FILE="${project_dir}/policy.yml"
    export DEVBOX_LOG_DIR="${project_dir}/logs"
    export DEVBOX_MEMORY_DIR="${project_dir}/memory"
    export DEVBOX_HISTORY_DIR="${project_dir}/history"
    export DEVBOX_SECRETS_FILE="${DEVBOX_DATA}/secrets/.env"
    export DEVBOX_PROJECT_SECRETS_FILE="${project_dir}/secrets/.env"
    export DEVBOX_CONFIG
    export DEVBOX_RELOAD_INTERVAL="${DEVBOX_RELOAD_INTERVAL:-30}"
    export DEVBOX_BRIDGE_SUBNET="${DEVBOX_BRIDGE_SUBNET:-}"

    docker compose -f "${DEVBOX_ROOT}/docker-compose.yml" \
        -p "$project" up -d --force-recreate agent
    ui_info "Resized. Run 'devbox shell' to reconnect."
}

cmd_rebuild() {
    if ! ui_confirm "Rebuild devbox images? This may take a few minutes."; then
        ui_info "Cancelled."
        return 0
    fi
    ui_info "Building devbox images..."
    container_build
    ui_info "Done."
}

cmd_update() {
    ui_info "Updating devbox..."

    # Warn if sessions are running — update rebuilds images.
    local running
    running="$(_find_devbox_projects)"
    if [ -n "$running" ]; then
        ui_warn "Running sessions detected. They will use old images until restarted."
        if ! ui_confirm "Continue with update?"; then
            ui_info "Update cancelled."
            return 0
        fi
    fi

    # Check if we're in a git repo (installed via git clone).
    if [ ! -d "${DEVBOX_ROOT}/.git" ]; then
        ui_error "Cannot update: devbox was not installed via git."
        ui_info "Re-install with: git clone https://github.com/d0cd/devbox.git"
        return 1
    fi

    # Check for local modifications (staged or unstaged).
    local stashed=false
    if ! git -C "${DEVBOX_ROOT}" diff --quiet 2>/dev/null \
        || ! git -C "${DEVBOX_ROOT}" diff --cached --quiet 2>/dev/null; then
        ui_warn "Local modifications detected in ${DEVBOX_ROOT}."
        if ! ui_confirm "Stash local changes and update?"; then
            ui_info "Update cancelled."
            return 0
        fi
        git -C "${DEVBOX_ROOT}" stash
        stashed=true
    fi

    # Pull latest.
    if ! git -C "${DEVBOX_ROOT}" pull --ff-only; then
        ui_error "Failed to pull latest changes. Your branch may have diverged."
        if [ "$stashed" = true ]; then
            ui_info "Restoring stashed changes..."
            git -C "${DEVBOX_ROOT}" stash pop
        fi
        ui_info "Resolve manually in ${DEVBOX_ROOT}"
        return 1
    fi

    # Rebuild images with new source.
    ui_info "Rebuilding images with updated source..."
    container_build
    ui_info "Update complete."
}

cmd_help() {
    cat <<HELP
devbox v${DEVBOX_VERSION} — isolated containerized development environment

USAGE:
  devbox [project-path]    Start environment and open shell (default: current dir)
  devbox shell             Open another shell into running environment
  devbox stop              Stop the running container stack
  devbox status            Show running sessions
  devbox info              Show container status and project info
  devbox profile [name]    Install a language profile (interactive if no name)
  devbox profile list      List available profiles and variants
  devbox allowlist         View the network allowlist
  devbox allowlist add X [Y ...]  Add domain(s) (supports *.domain.com wildcards)
  devbox allowlist remove X  Remove domain X (alias: rm)
  devbox allowlist reset   Reset allowlist to defaults
  devbox secrets           Show API keys (values masked)
  devbox secrets set K V   Set a secret (e.g., devbox secrets set ANTHROPIC_API_KEY sk-...)
  devbox secrets set --project K V  Set a per-project secret
  devbox secrets remove K  Remove a secret
  devbox secrets edit      Open secrets file in \$EDITOR
  devbox secrets path      Print secrets file path
  devbox logs              Show recent API calls (requires sqlite3)
  devbox logs --errors     Show recent 4xx/5xx responses
  devbox logs --blocked    Show requests blocked by enforcer (403)
  devbox logs --slow       Show requests slower than 5 seconds
  devbox logs --hosts      Show request counts grouped by host
  devbox logs --since T    Filter to requests after timestamp T
  devbox logs --until T    Filter to requests before timestamp T
  devbox resize 12G        Resize agent to 12 GB RAM (restarts container)
  devbox resize 16G 8      Resize to 16 GB RAM and 8 CPUs
  devbox clean             Clean this project's data
  devbox clean --all       Clean all devbox data
  devbox rebuild           Rebuild container images
  devbox update            Pull latest source and rebuild images
  devbox completions       Output shell completions (source <(devbox completions))
  devbox help              Show this help
  devbox --version         Show version

WORKFLOW:
  The container is an isolated dev environment. Start it once, then exec in:
    devbox                   # First pane — starts environment + shell
    devbox shell             # Additional panes — shell into running env
  Inside the container, run any tool directly:
    claude                   # Claude Code session
    opencode                 # OpenCode session (with PAL MCP dispatch)
    nvim .                   # Neovim (if configured via private overlay)
    gemini                   # Gemini CLI
    codex                    # Codex CLI

CONFIGURATION:
  Place a .devboxrc file in your project directory to set defaults:
    DEVBOX_BRIDGE_SUBNET=172.18.0.0/16
    DEVBOX_RELOAD_INTERVAL=30
    DEVBOX_MEMORY=12G
    DEVBOX_CPUS=6
    DEVBOX_PRIVATE_CONFIGS=git@github.com:you/devbox-private.git
  Environment variables take precedence over .devboxrc values.

PROFILES:
  rust [wasm]              Rust toolchain + cargo extensions
  python [ml|api]          Python + uv + dev tools
  node [bun]               Node.js LTS + pnpm + dev tools
  go                       Go toolchain + golangci-lint + delve

FLAGS:
  --quiet, -q              Suppress informational output (for scripting)

ENVIRONMENT:
  DEVBOX_QUIET             Set to 1 for quiet mode (same as --quiet)
  DEVBOX_NO_SECRETS        Set to 1 to start without API keys configured
  DEVBOX_DATA              Data directory (default: ~/.devbox)
  DEVBOX_CONFIG            Config directory (default: ~/.config/devbox)
  DEVBOX_MEMORY            Agent container memory limit (default: 8G)
  DEVBOX_CPUS              Agent container CPU limit (default: 4.0)
  DEVBOX_BRIDGE_SUBNET     Override Docker bridge subnet for firewall rules
  DEVBOX_RELOAD_INTERVAL   Policy reload interval in seconds (default: 30)
  DEVBOX_PRIVATE_CONFIGS   Git URL or local path for private config overlay

PRIVATE CONFIGS:
  Set DEVBOX_PRIVATE_CONFIGS to a git URL or local directory path:
    DEVBOX_PRIVATE_CONFIGS=~/configs               # local directory
    DEVBOX_PRIVATE_CONFIGS=git@github.com:you/c.git  # git repo
  The source should have top-level dirs for each tool you want to customize:
    claude/                Claude Code config (CLAUDE.md, settings, hooks)
    opencode/              OpenCode config (opencode.json, agents, skills)
    nvim/                  Neovim config (init.lua, plugins, etc.)
    tmux/                  Tmux config (tmux.conf, tmux.conf.local)
    .zshrc                 Zsh config (replaces default devbox zshrc)
  These are copied into the container at startup, overriding defaults.
  Add a Dockerfile to pre-build heavy installs into the cached image:
    FROM devbox-agent:latest
    COPY nvim/ /home/devbox/.config/nvim/
    COPY tmux/ /home/devbox/.config/tmux/
    COPY .zshrc /home/devbox/.zshrc
    RUN gosu devbox nvim --headless "+Lazy! sync" +qa
  Example: DEVBOX_PRIVATE_CONFIGS=git@github.com:you/devbox-private.git
HELP
}
