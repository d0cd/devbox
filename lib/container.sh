#!/usr/bin/env bash
# Container lifecycle management for devbox.
#
# Manages the Docker Compose stack (agent + proxy sidecar) for a project.
# The container runs as an isolated dev environment — users exec into it.
# All functions expect DEVBOX_ROOT, DEVBOX_DATA, and DEVBOX_CONFIG to be set.
set -euo pipefail

# Build compose file arguments. Includes the private override if present.
# Usage: docker compose $(_compose_file_args) -p "project" up -d
_compose_file_args() {
    echo -n "-f ${DEVBOX_ROOT}/docker-compose.yml"
    local override="${DEVBOX_CONFIG:+${DEVBOX_CONFIG}/.private/docker-compose.override.yml}"
    if [ -n "$override" ] && [ -f "$override" ]; then
        echo -n " -f ${override}"
    fi
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
        # Fallback: extract names with grep/sed.
        echo "$json" | grep -o '"Name":"devbox-[^"]*"' | sed 's/"Name":"//;s/"//' 2>/dev/null
    fi
}

# Find a single running devbox project. If multiple are running, offer an
# interactive selector (or fail non-interactively).
_require_single_project() {
    local projects
    projects="$(_find_devbox_projects)"

    if [ -z "$projects" ]; then
        ui_error "No running devbox session found."
        ui_info "Start one with: devbox [project-path]"
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
            local hash="${p#devbox-}"
            local path_label="(unknown path)"
            if [ -f "${DEVBOX_DATA}/${hash}/.project_path" ]; then
                path_label="$(cat "${DEVBOX_DATA}/${hash}/.project_path")"
                path_label="${path_label/#$HOME/\~}"
            fi
            echo "  ${i}) ${path_label} (${p})" >&2
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
        docker build -f "$private_dockerfile" -t devbox-agent:latest "${DEVBOX_CONFIG}/.private/"
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

# Start the container stack for a project and drop into a shell.
container_start() {
    local project_path="$1"
    local hash="$2"
    local project_dir="${DEVBOX_DATA}/${hash}"

    # Prevent concurrent starts for the same project.
    _acquire_project_lock "${project_dir}/.start.lock" || return 1

    # Export variables for docker-compose.yml interpolation.
    export PROJECT_PATH="$project_path"
    export PROJECT_HASH="$hash"
    export DEVBOX_POLICY_FILE="${project_dir}/policy.yml"
    export DEVBOX_LOG_DIR="${project_dir}/logs"
    export DEVBOX_MEMORY_DIR="${project_dir}/memory"
    export DEVBOX_HISTORY_DIR="${project_dir}/history"
    export DEVBOX_SECRETS_FILE="${DEVBOX_DATA}/secrets/.env"
    export DEVBOX_PROJECT_SECRETS_FILE="${project_dir}/secrets/.env"
    export DEVBOX_CONFIG
    # Resource limits (defaults in docker-compose.yml: 8G / 4 CPUs).
    export DEVBOX_MEMORY="${DEVBOX_MEMORY:-8G}"
    export DEVBOX_CPUS="${DEVBOX_CPUS:-4.0}"

    # Validate secrets file early — fail fast before touching Docker.
    # Users can bypass with DEVBOX_NO_SECRETS=1 for non-AI workflows.
    local secrets_file="${DEVBOX_SECRETS_FILE}"
    local has_keys=false
    if [ -f "$secrets_file" ] && grep -q '_API_KEY=[a-zA-Z0-9]' "$secrets_file" 2>/dev/null; then
        has_keys=true
    fi

    if [ "$has_keys" = false ] && [ "${DEVBOX_NO_SECRETS:-}" != "1" ]; then
        ui_error "No API keys configured. AI tools won't work without them."
        echo "" >&2
        ui_warn "Set at least one API key:"
        ui_warn "  devbox secrets set ANTHROPIC_API_KEY sk-ant-..."
        ui_warn "  devbox secrets set OPENROUTER_API_KEY sk-or-..."
        ui_warn "  devbox secrets set GEMINI_API_KEY AIza..."
        ui_warn "  devbox secrets set OPENAI_API_KEY sk-..."
        echo "" >&2
        ui_info "Then run 'devbox' again."
        ui_info "To start without keys: DEVBOX_NO_SECRETS=1 devbox"
        return 1
    fi

    # Build compose file arguments (includes private override if present).
    local compose_args
    compose_args="$(_compose_file_args)"

    # Detect if this project's stack is already running.
    local running_projects
    running_projects="$(_find_devbox_projects)"
    if echo "$running_projects" | grep -q "^devbox-${hash}$"; then
        ui_info "Environment already running."
        docker compose $compose_args \
            -p "devbox-${hash}" exec agent gosu devbox zsh
        return $?
    fi

    # Build images if they don't exist.
    if ! docker image inspect devbox-agent:latest &>/dev/null \
        || ! docker image inspect devbox-proxy:latest &>/dev/null; then
        ui_info "Building devbox images (this may take several minutes on first run)..."
        container_build
    fi

    # Start the stack in detached mode.
    ui_info "Starting environment..."
    docker compose $compose_args \
        -p "devbox-${hash}" up -d

    # Wait for agent container to accept exec sessions.
    ui_spinner "Waiting for environment to be ready..." &
    local spinner_pid=$!
    trap 'kill $spinner_pid 2>/dev/null; wait $spinner_pid 2>/dev/null' RETURN

    local elapsed=0
    while ! docker compose $compose_args \
        -p "devbox-${hash}" exec -T agent true &>/dev/null 2>&1; do
        sleep 1
        elapsed=$((elapsed + 1))

        # Check every 5s if the container has exited/crashed — fail fast.
        if [ $((elapsed % 5)) -eq 0 ]; then
            local container_status
            local ps_json
            ps_json="$(docker compose $compose_args \
                -p "devbox-${hash}" ps --format json 2>/dev/null || true)"
            if command -v jq &>/dev/null; then
                container_status="$(echo "$ps_json" | jq -r '
                    if type == "array" then .[0] else . end | .State // empty
                ' 2>/dev/null || true)"
            else
                container_status="$(echo "$ps_json" \
                    | grep -o '"State":"[^"]*"' | head -1 | sed 's/"State":"//;s/"//' || true)"
            fi
            if [ "$container_status" = "exited" ] || [ "$container_status" = "dead" ]; then
                kill $spinner_pid 2>/dev/null
                wait $spinner_pid 2>/dev/null
                trap - RETURN
                printf "\r"
                ui_error "Container exited unexpectedly."
                ui_info "Check logs: docker compose -p devbox-${hash} logs"
                return 1
            fi
        fi

        if [ "$elapsed" -ge 60 ]; then
            kill $spinner_pid 2>/dev/null
            wait $spinner_pid 2>/dev/null
            trap - RETURN
            printf "\r"
            ui_error "Environment did not start within 60 seconds."
            ui_info "Check logs: docker compose -p devbox-${hash} logs"
            return 1
        fi
    done

    kill $spinner_pid 2>/dev/null
    wait $spinner_pid 2>/dev/null
    trap - RETURN
    printf "\r"
    ui_info "Environment ready."
    docker compose $compose_args \
        -p "devbox-${hash}" exec agent gosu devbox zsh
}

# Open a shell in the running agent container.
container_shell() {
    local project
    project="$(_require_single_project)"
    docker compose $(_compose_file_args) -p "$project" exec agent gosu devbox zsh
}

# Stop the container stack.
container_stop() {
    local project
    project="$(_require_single_project)"
    docker compose $(_compose_file_args) -p "$project" down
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
            local hash="${project#devbox-}"
            local path_label="(unknown path)"
            if [ -f "${DEVBOX_DATA}/${hash}/.project_path" ]; then
                path_label="$(cat "${DEVBOX_DATA}/${hash}/.project_path")"
                # Shorten home directory prefix for readability.
                path_label="${path_label/#$HOME/\~}"
            fi
            echo "  ${project}"
            echo "    Path:  ${path_label}"
            echo "    Shell: devbox shell"

            # Show resource usage and warnings for the agent container.
            _container_resource_warnings "$project"
        done <<<"$projects"
    fi
}

# Check resource usage for a running project and warn if near limits.
_container_resource_warnings() {
    local project="$1"
    local stats
    stats="$(docker compose $(_compose_file_args) -p "$project" ps -q agent 2>/dev/null)" || return 0
    [ -z "$stats" ] && return 0

    local container_id="$stats"
    local usage
    usage="$(docker stats --no-stream --format '{{.MemUsage}}|{{.MemPerc}}|{{.BlockIO}}' "$container_id" 2>/dev/null)" || return 0
    [ -z "$usage" ] && return 0

    local mem_usage mem_pct block_io
    mem_usage="$(echo "$usage" | cut -d'|' -f1 | xargs)"
    mem_pct="$(echo "$usage" | cut -d'|' -f2 | tr -d '% ' | cut -d'.' -f1)"
    block_io="$(echo "$usage" | cut -d'|' -f3 | xargs)"

    echo "    Memory: ${mem_usage} (${mem_pct}%)"
    echo "    Disk:   ${block_io}"

    # Warn at 80% memory usage.
    if [ -n "$mem_pct" ] && [ "$mem_pct" -ge 80 ] 2>/dev/null; then
        ui_warn "Agent is using ${mem_pct}% of its memory limit."
        ui_warn "Increase with: DEVBOX_MEMORY=12G devbox  (or set in .devboxrc)"
    fi
}
