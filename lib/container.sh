#!/usr/bin/env bash
# Container lifecycle management for devbox.
#
# Manages the Docker Compose stack (agent + proxy sidecar) for a project.
# The container runs as an isolated dev environment — users exec into it.
# All functions expect DEVBOX_ROOT, DEVBOX_DATA, and DEVBOX_CONFIG to be set.
set -euo pipefail

# ---------------------------------------------------------------------------
# cmux integration (host-side)
# ---------------------------------------------------------------------------
# Detect if running inside cmux and set sidebar status/notifications.
# These are no-ops when cmux is not available.

_cmux_available() {
    command -v cmux &>/dev/null && [ -n "${CMUX_WORKSPACE_ID:-}" ]
}

# Set a sidebar status pill for the devbox session.
_cmux_set_status() {
    _cmux_available || return 0
    cmux set-status devbox "$1" --icon=bolt.fill --color='#4C8DFF' 2>/dev/null || true
}

# Clear the devbox sidebar status pill.
_cmux_clear_status() {
    _cmux_available || return 0
    cmux clear-status devbox 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# cmux filtering proxy lifecycle
# ---------------------------------------------------------------------------

_CMUX_PROXY_PID="${DEVBOX_DATA}/cmux-proxy.pid"
_CMUX_PROXY_PORT_FILE="${DEVBOX_DATA}/cmux-proxy.port"

# Start the cmux filtering proxy if running inside cmux and not already alive.
# Exports DEVBOX_CMUX_PROXY_PORT for docker-compose.yml interpolation.
_cmux_proxy_start() {
    _cmux_available || return 0
    [ -n "${CMUX_SOCKET_PATH:-}" ] || return 0

    # Reuse existing proxy if alive.
    if [ -f "$_CMUX_PROXY_PID" ]; then
        local pid
        pid="$(cat "$_CMUX_PROXY_PID" 2>/dev/null)" || true
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            if [ -f "$_CMUX_PROXY_PORT_FILE" ]; then
                export DEVBOX_CMUX_PROXY_PORT="$(cat "$_CMUX_PROXY_PORT_FILE")"
                return 0
            fi
        fi
    fi

    # Spawn proxy in background.
    python3 "${DEVBOX_ROOT}/tooling/cmux-proxy.py" &
    local proxy_pid=$!
    disown "$proxy_pid" 2>/dev/null || true

    # Wait for port file (up to 3s, polling every 0.5s).
    local elapsed=0
    while [ ! -f "$_CMUX_PROXY_PORT_FILE" ] && [ "$elapsed" -lt 6 ]; do
        sleep 0.5
        elapsed=$((elapsed + 1))
    done

    if [ -f "$_CMUX_PROXY_PORT_FILE" ]; then
        export DEVBOX_CMUX_PROXY_PORT="$(cat "$_CMUX_PROXY_PORT_FILE")"
    fi
}

# Stop the cmux proxy if this is the last running devbox session.
_cmux_proxy_stop() {
    [ -f "$_CMUX_PROXY_PID" ] || return 0

    # Don't kill the proxy if other sessions are still running.
    local remaining
    remaining="$(_find_devbox_projects)"
    if [ -n "$remaining" ]; then
        return 0
    fi

    local pid
    pid="$(cat "$_CMUX_PROXY_PID" 2>/dev/null)" || true
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
    fi
    rm -f "$_CMUX_PROXY_PID" "$_CMUX_PROXY_PORT_FILE"
}

# Build compose file arguments. Includes the private override if present.
# Usage: docker compose $(_compose_file_args) -p "project" up -d
_compose_file_args() {
    echo -n "-f ${DEVBOX_ROOT}/docker-compose.yml"
    local override="${DEVBOX_CONFIG:+${DEVBOX_CONFIG}/.private/docker-compose.override.yml}"
    if [ -n "$override" ] && [ -f "$override" ]; then
        echo -n " -f ${override}"
    fi
    # Per-project compose override (custom mounts from devbox mount add).
    # Validated to contain only volume directives — prevents security escalation.
    if [ -n "${PROJECT_HASH:-}" ]; then
        local project_override="${DEVBOX_DATA}/${PROJECT_HASH}/compose.override.yml"
        if [ -f "$project_override" ] && _validate_compose_override "$project_override"; then
            echo -n " -f ${project_override}"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Credential injection: proxy secrets and phantom token generation
# ---------------------------------------------------------------------------

# Known injectable API keys: source env var → proxy env var name.
# The mapping is intentionally hardcoded — only these keys are eligible
# for proxy-layer injection. The proxy's injector.py has a matching
# provider registry with the domain-to-header mapping.
declare -A _DEVBOX_INJECTABLE_KEYS=(
    [ANTHROPIC_API_KEY]=DEVBOX_INJECT_ANTHROPIC
    [OPENAI_API_KEY]=DEVBOX_INJECT_OPENAI
    [GEMINI_API_KEY]=DEVBOX_INJECT_GEMINI
    [GOOGLE_API_KEY]=DEVBOX_INJECT_GEMINI
    [OPENROUTER_API_KEY]=DEVBOX_INJECT_OPENROUTER
    [GH_TOKEN]=DEVBOX_INJECT_GITHUB
)

# Keys that should NOT get phantom replacements in the agent env.
# GH_TOKEN must remain real because git credential helpers need it.
declare -A _DEVBOX_KEEP_IN_AGENT=(
    [GH_TOKEN]=1
)

DEVBOX_PHANTOM_VALUE="sk-devbox-phantom-not-a-real-key"

# Generate proxy secrets file (.proxy.env) with DEVBOX_INJECT_* variables
# and agent phantom overrides file (.phantom.env).
# Reads from the global and per-project secrets files.
_generate_credential_files() {
    local project_dir="$1"
    local global_secrets="${DEVBOX_DATA}/secrets/.env"
    local project_secrets="${project_dir}/secrets/.env"
    local proxy_env="${project_dir}/secrets/.proxy.env"
    local phantom_env="${project_dir}/secrets/.phantom.env"

    # Disabled by escape hatch.
    if [ "${DEVBOX_CREDENTIAL_INJECTION:-true}" = "false" ]; then
        (umask 077 && true > "$proxy_env" && true > "$phantom_env")
        return 0
    fi

    local -A found_keys=()

    # Scan secrets files for injectable keys.
    local secrets_file
    for secrets_file in "$global_secrets" "$project_secrets"; do
        [ -f "$secrets_file" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            [[ "$line" =~ ^[[:space:]]*$ ]] && continue
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            local key="${line%%=*}"
            local value="${line#*=}"
            if [ -n "${_DEVBOX_INJECTABLE_KEYS[$key]+_}" ] && [ -n "$value" ]; then
                found_keys[$key]="$value"
            fi
        done < "$secrets_file"
    done

    # Write proxy secrets and phantom overrides.
    (
        umask 077
        true > "$proxy_env"
        true > "$phantom_env"
        local key value proxy_var
        for key in "${!found_keys[@]}"; do
            value="${found_keys[$key]}"
            proxy_var="${_DEVBOX_INJECTABLE_KEYS[$key]}"
            echo "${proxy_var}=${value}" >> "$proxy_env"
            # Only generate phantom for keys not in the keep-in-agent list.
            if [ -z "${_DEVBOX_KEEP_IN_AGENT[$key]+_}" ]; then
                echo "${key}=${DEVBOX_PHANTOM_VALUE}" >> "$phantom_env"
            fi
        done
    )
}

# Export all environment variables required by docker-compose.yml interpolation.
# Reconstructs paths from a compose project name (devbox-name-hash or devbox-hash).
_export_compose_env() {
    local project="$1"
    local hash
    hash="$(_hash_from_compose_project "$project")"
    local project_dir="${DEVBOX_DATA}/${hash}"
    local project_path="."
    [ -f "${project_dir}/.project_path" ] && project_path="$(cat "${project_dir}/.project_path")"
    export PROJECT_PATH="$project_path"
    export PROJECT_HASH="$hash"
    export DEVBOX_POLICY_FILE="${project_dir}/policy.yml"
    export DEVBOX_LOG_DIR="${project_dir}/logs"
    export DEVBOX_MEMORY_DIR="${project_dir}/memory"
    export DEVBOX_HISTORY_DIR="${project_dir}/history"
    export DEVBOX_SECRETS_FILE="${DEVBOX_DATA}/secrets/.env"
    export DEVBOX_PROJECT_SECRETS_FILE="${project_dir}/secrets/.env"
    export DEVBOX_CONFIG
    # Resolve the private configs symlink so Docker gets the real path (not a dangling symlink).
    # Falls back to an empty directory so the compose mount always has a valid source.
    if [ -L "${DEVBOX_CONFIG}/.private" ] && [ -d "${DEVBOX_CONFIG}/.private" ]; then
        export DEVBOX_PRIVATE_DIR="$(cd "${DEVBOX_CONFIG}/.private" && pwd -P)"
    elif [ -d "${DEVBOX_CONFIG}/.private" ]; then
        export DEVBOX_PRIVATE_DIR="${DEVBOX_CONFIG}/.private"
    else
        mkdir -p "${DEVBOX_CONFIG}/.private-empty"
        export DEVBOX_PRIVATE_DIR="${DEVBOX_CONFIG}/.private-empty"
    fi
    # Claude Code state — global across all devbox projects. Credentials, plans,
    # conversations, plugins all persist here. Separate from the host's ~/.claude/.
    export DEVBOX_CLAUDE_DIR="${DEVBOX_DATA}/claude"
    export DEVBOX_PROJECT_NAME="$(_project_name_for_hash "$hash")"
    export DEVBOX_MEMORY="${DEVBOX_MEMORY:-8G}"
    export DEVBOX_CPUS="${DEVBOX_CPUS:-4.0}"

    # Generate proxy credential injection and agent phantom token files.
    _generate_credential_files "$project_dir"
    export DEVBOX_PROXY_SECRETS_FILE="${project_dir}/secrets/.proxy.env"
    export DEVBOX_PHANTOM_FILE="${project_dir}/secrets/.phantom.env"

    # Start cmux filtering proxy if running inside cmux.
    _cmux_proxy_start
    export DEVBOX_CMUX_PROXY_PORT="${DEVBOX_CMUX_PROXY_PORT:-}"
}

# Find running devbox compose projects. Outputs one project name per line.
# Uses jq if available, falls back to grep-based parsing.
_find_devbox_projects() {
    local json
    json="$(docker compose ls --format json 2>/dev/null)" || return 0

    if command -v jq &>/dev/null; then
        # Handle both JSON array and NDJSON (Docker Compose v2.21+) formats.
        echo "$json" | jq -r '
            if type == "array" then .[] else . end |
            select(.Name | startswith("devbox-")) | .Name
        ' 2>/dev/null
    else
        # Fallback: extract names with grep. Handles both JSON array and NDJSON.
        echo "$json" | grep -oE '"Name"\s*:\s*"devbox-[^"]*"' | grep -oE 'devbox-[^"]*' 2>/dev/null
    fi
}

# Find a running devbox project by name, or interactively select one.
# Usage: _require_single_project [name]
_require_single_project() {
    local target_name="${1:-}"
    local projects
    projects="$(_find_devbox_projects)"

    if [ -z "$projects" ]; then
        ui_error "No running devbox session found."
        ui_info "Start one with: devbox [project-path]"
        return 1
    fi

    # If a name was given, find the matching running project.
    if [ -n "$target_name" ]; then
        while IFS= read -r p; do
            local hash
            hash="$(_hash_from_compose_project "$p")"
            local name
            name="$(_project_name_for_hash "$hash")"
            if [ "$name" = "$target_name" ]; then
                echo "$p"
                return 0
            fi
        done <<<"$projects"
        ui_error "No running session named '${target_name}'."
        return 1
    fi

    local count
    count="$(echo "$projects" | wc -l | tr -d ' ')"
    if [ "$count" -gt 1 ]; then
        # Non-interactive — can't prompt.
        if [ ! -t 0 ]; then
            ui_error "Multiple devbox sessions running. Cannot select non-interactively."
            return 1
        fi
        ui_warn "Multiple devbox sessions running:"
        local -a project_list=()
        local i=1
        while IFS= read -r p; do
            project_list+=("$p")
            local hash
            hash="$(_hash_from_compose_project "$p")"
            local name
            name="$(_project_name_for_hash "$hash")"
            local path_label="(unknown path)"
            if [ -f "${DEVBOX_DATA}/${hash}/.project_path" ]; then
                path_label="$(cat "${DEVBOX_DATA}/${hash}/.project_path")"
                path_label="${path_label/#$HOME/\~}"
            fi
            echo "  ${i}) ${name} — ${path_label}" >&2
            i=$((i + 1))
        done <<<"$projects"

        local choice
        echo -n "Select session [1-${count}]: " >&2
        read -r choice
        if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
            ui_error "Invalid selection."
            return 1
        fi
        echo "${project_list[$((choice - 1))]}"
        return 0
    fi

    echo "$projects"
}

# Build both container images, plus private overlay if present.
container_build() {
    ui_info "Building devbox images (this may take several minutes on first run)..."

    # Ensure required compose variables are set for file parsing.
    # These are only used at runtime (env_file, volumes), not during build.
    export DEVBOX_SECRETS_FILE="${DEVBOX_SECRETS_FILE:-${DEVBOX_DATA}/secrets/.env}"
    export DEVBOX_PROJECT_SECRETS_FILE="${DEVBOX_PROJECT_SECRETS_FILE:-/dev/null}"
    export DEVBOX_CONFIG="${DEVBOX_CONFIG:-$HOME/.config/devbox}"
    if [ -z "${DEVBOX_PRIVATE_DIR:-}" ]; then
        mkdir -p "${DEVBOX_CONFIG}/.private-empty"
        export DEVBOX_PRIVATE_DIR="${DEVBOX_CONFIG}/.private-empty"
    fi
    export DEVBOX_CLAUDE_DIR="${DEVBOX_CLAUDE_DIR:-/tmp/devbox-claude-data}"
    mkdir -p "${DEVBOX_CLAUDE_DIR}" 2>/dev/null || true
    export PROJECT_PATH="${PROJECT_PATH:-.}"
    export DEVBOX_PROXY_SECRETS_FILE="${DEVBOX_PROXY_SECRETS_FILE:-/dev/null}"
    export DEVBOX_PHANTOM_FILE="${DEVBOX_PHANTOM_FILE:-/dev/null}"
    export DEVBOX_CMUX_PROXY_PORT="${DEVBOX_CMUX_PROXY_PORT:-}"

    local compose_args
    compose_args="$(_compose_file_args)"

    ui_info "[1/3] Building proxy sidecar..."
    docker compose $compose_args build --progress=auto proxy
    ui_info "[1/3] Proxy sidecar built."

    ui_info "[2/3] Building agent container..."
    docker compose $compose_args build --progress=auto agent
    ui_info "[2/3] Agent container built."

    # Build private overlay if a Dockerfile exists in the private config repo.
    # The private Dockerfile should use FROM devbox-agent:latest and add user configs.
    local private_dockerfile="${DEVBOX_CONFIG}/.private/Dockerfile"
    if [ -f "$private_dockerfile" ]; then
        ui_info "[3/3] Building private config overlay (nvim plugins, etc.)..."
        # Build context is the parent of .private/ so the Dockerfile can
        # reference sibling directories (nvim/, tmux/) without symlinks.
        local private_dir
        private_dir="$(cd "${DEVBOX_CONFIG}/.private" && pwd -P)"
        local build_context
        build_context="$(dirname "$private_dir")"
        docker build -f "$private_dockerfile" -t devbox-agent:latest "$build_context"
        ui_info "[3/3] Private overlay applied."
    else
        ui_info "[3/3] No private overlay Dockerfile found, skipping."
    fi

    ui_info "Build complete."
}

# Acquire a per-project lock to prevent concurrent devbox invocations from racing.
# Uses flock where available; falls back to no lock on macOS (acceptable since
# Docker Compose itself serializes container operations).
_acquire_project_lock() {
    local lock_file="$1"
    if command -v flock &>/dev/null; then
        # Open lock fd (9) and acquire exclusive lock with timeout.
        exec 9>"$lock_file"
        if ! flock -w 5 9; then
            ui_error "Another devbox session is starting for this project. Wait or check running sessions."
            return 1
        fi
    fi
}

# Stop a background spinner and clear the line.
_stop_spinner() {
    local pid="$1"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    printf "\r"
}

# Start the container stack for a project and drop into a shell.
container_start() {
    local project_path="$1"
    local hash="$2"
    local project_dir="${DEVBOX_DATA}/${hash}"

    # Prevent concurrent starts for the same project.
    _acquire_project_lock "${project_dir}/.start.lock" || return 1

    # Determine project name.
    local name="${DEVBOX_NAME:-$(basename "$project_path")}"
    local compose_project
    compose_project="$(_compose_project_name "$name" "$hash")"

    # Export variables for docker-compose.yml interpolation.
    _export_compose_env "$compose_project"
    # Override PROJECT_PATH with the actual argument (first run: .project_path may not exist yet).
    export PROJECT_PATH="$project_path"
    export DEVBOX_PROJECT_NAME="$name"

    # Build compose file arguments (includes private override if present).
    local compose_args
    compose_args="$(_compose_file_args)"

    # Detect if this project's stack is already running.
    local running_projects
    running_projects="$(_find_devbox_projects)"
    if echo "$running_projects" | grep -q "^${compose_project}$"; then
        ui_info "Environment already running."
        _cmux_set_status "running"
        docker compose $compose_args \
            -p "${compose_project}" exec agent gosu devbox zsh
        local rc=$?
        _cmux_clear_status
        return $rc
    fi

    # Build base images if they don't exist.
    if ! docker image inspect devbox-agent:latest &>/dev/null \
        || ! docker image inspect devbox-proxy:latest &>/dev/null; then
        ui_info "Building devbox images (this may take several minutes on first run)..."
        container_build
    else
        # Base images exist, but ensure private overlay is applied.
        # The overlay re-tags devbox-agent:latest with user customizations.
        local private_dockerfile="${DEVBOX_CONFIG}/.private/Dockerfile"
        if [ -f "$private_dockerfile" ]; then
            local private_dir
            private_dir="$(cd "${DEVBOX_CONFIG}/.private" && pwd -P)"
            local build_context
            build_context="$(dirname "$private_dir")"
            if ! docker build -q -f "$private_dockerfile" -t devbox-agent:latest "$build_context" >/dev/null 2>&1; then
                ui_warn "Private overlay build failed — continuing with base image."
            fi
        fi
    fi

    # Start the stack in detached mode.
    ui_info "Starting environment..."
    docker compose $compose_args \
        -p "${compose_project}" up -d

    # Wait for agent container to accept exec sessions.
    ui_spinner "Waiting for environment to be ready..." &
    local spinner_pid=$!
    trap 'kill $spinner_pid 2>/dev/null; wait $spinner_pid 2>/dev/null' RETURN

    local elapsed=0
    while ! docker compose $compose_args \
        -p "${compose_project}" exec -T agent test -f /tmp/.devbox-ready &>/dev/null 2>&1; do
        sleep 1
        elapsed=$((elapsed + 1))

        # Check every 5s if the container has exited/crashed — fail fast.
        if [ $((elapsed % 5)) -eq 0 ]; then
            local container_status
            local ps_json
            ps_json="$(docker compose $compose_args \
                -p "${compose_project}" ps --format json 2>/dev/null || true)"
            if command -v jq &>/dev/null; then
                container_status="$(echo "$ps_json" | jq -r '
                    if type == "array" then .[0] else . end | .State // empty
                ' 2>/dev/null || true)"
            else
                container_status="$(echo "$ps_json" \
                    | grep -o '"State":"[^"]*"' | head -1 | sed 's/"State":"//;s/"//' || true)"
            fi
            if [ "$container_status" = "exited" ] || [ "$container_status" = "dead" ]; then
                _stop_spinner $spinner_pid
                trap - RETURN
                ui_error "Container exited unexpectedly."
                ui_info "Check logs: docker compose -p ${compose_project} logs"
                return 1
            fi
        fi

        if [ "$elapsed" -ge 60 ]; then
            _stop_spinner $spinner_pid
            trap - RETURN
            ui_error "Environment did not start within 60 seconds."
            ui_info "Check logs: docker compose -p ${compose_project} logs"
            return 1
        fi
    done

    _stop_spinner $spinner_pid
    trap - RETURN
    ui_info "Environment ready."
    _cmux_set_status "running"
    docker compose $compose_args \
        -p "${compose_project}" exec agent gosu devbox zsh
    _cmux_clear_status
}

# Open a shell in the running agent container.
container_shell() {
    local target_name="${1:-}"
    local project
    project="$(_require_single_project "$target_name")"
    _export_compose_env "$project"
    _cmux_set_status "running"
    docker compose $(_compose_file_args) -p "$project" exec agent gosu devbox zsh
    _cmux_clear_status
}

# Show the status of running devbox containers with project details.
container_status() {
    local projects
    projects="$(_find_devbox_projects)"

    if [ -z "$projects" ]; then
        ui_info "No running devbox sessions."
    else
        ui_header "Running Sessions"
        while IFS= read -r project; do
            local hash
            hash="$(_hash_from_compose_project "$project")"
            local name
            name="$(_project_name_for_hash "$hash")"
            local path_label="(unknown path)"
            if [ -f "${DEVBOX_DATA}/${hash}/.project_path" ]; then
                path_label="$(cat "${DEVBOX_DATA}/${hash}/.project_path")"
                path_label="${path_label/#$HOME/\~}"
            fi
            echo "  ${name}"
            echo "    Path:  ${path_label}"
            echo "    Shell: devbox ${name}"

            # Show resource usage and warnings for the agent container.
            _container_resource_warnings "$project"
        done <<<"$projects"
    fi
}

# Check resource usage for a running project and warn if near limits.
_container_resource_warnings() {
    local project="$1"
    _export_compose_env "$project"
    local stats
    stats="$(docker compose $(_compose_file_args) -p "$project" ps -q agent 2>/dev/null)" || return 0
    [ -z "$stats" ] && return 0

    local container_id="$stats"
    local usage
    usage="$(docker stats --no-stream --format '{{.MemUsage}}|{{.MemPerc}}' "$container_id" 2>/dev/null)" || return 0
    [ -z "$usage" ] && return 0

    local mem_usage mem_pct
    mem_usage="$(echo "$usage" | cut -d'|' -f1 | xargs)"
    mem_pct="$(echo "$usage" | cut -d'|' -f2 | tr -d '% ' | cut -d'.' -f1)"

    echo "    Memory: ${mem_usage} (${mem_pct}%)"

    # Show container writable layer size (actual disk used on top of image).
    local disk_size
    disk_size="$(docker ps -s --filter "id=$container_id" --format '{{.Size}}' 2>/dev/null)" || true
    if [ -n "$disk_size" ]; then
        echo "    Disk:   ${disk_size}"
    fi

    # Warn at 80% memory usage.
    if [ -n "$mem_pct" ] && [ "$mem_pct" -ge 80 ] 2>/dev/null; then
        ui_warn "Agent is using ${mem_pct}% of its memory limit."
        ui_warn "Increase with: DEVBOX_MEMORY=12G devbox  (or set in .devboxrc)"
    fi
}
