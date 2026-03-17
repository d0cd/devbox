#!/usr/bin/env bats
# Tests for lib/container.sh — container lifecycle with mocked Docker.

load test_helper

setup() {
    setup_libs
    stub_devbox_env
    source "${DEVBOX_ROOT}/lib/container.sh"
}

teardown() {
    rm -rf "$DEVBOX_DATA" "$DEVBOX_CONFIG" 2>/dev/null || true
}

# --- _find_devbox_projects ---

@test "find_devbox_projects parses JSON array format" {
    docker() {
        if [[ "$*" == *"compose ls"* ]]; then
            echo '[{"Name":"devbox-abc123","Status":"running(2)"}]'
        fi
    }
    export -f docker
    run _find_devbox_projects
    [ "$status" -eq 0 ]
    [[ "$output" == *"devbox-abc123"* ]]
}

@test "find_devbox_projects parses NDJSON format" {
    docker() {
        if [[ "$*" == *"compose ls"* ]]; then
            echo '{"Name":"devbox-abc123","Status":"running(2)"}'
            echo '{"Name":"devbox-def456","Status":"running(1)"}'
        fi
    }
    export -f docker
    run _find_devbox_projects
    [ "$status" -eq 0 ]
    [[ "$output" == *"devbox-abc123"* ]]
    [[ "$output" == *"devbox-def456"* ]]
}

@test "find_devbox_projects returns empty when none running" {
    docker() {
        if [[ "$*" == *"compose ls"* ]]; then
            echo '[]'
        fi
    }
    export -f docker
    run _find_devbox_projects
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "find_devbox_projects ignores non-devbox projects" {
    docker() {
        if [[ "$*" == *"compose ls"* ]]; then
            echo '[{"Name":"other-project","Status":"running(1)"},{"Name":"devbox-abc123","Status":"running(2)"}]'
        fi
    }
    export -f docker
    run _find_devbox_projects
    [ "$status" -eq 0 ]
    [[ "$output" == *"devbox-abc123"* ]]
    [[ "$output" != *"other-project"* ]]
}

# --- _require_single_project ---

@test "require_single_project errors when none running" {
    docker() {
        if [[ "$*" == *"compose ls"* ]]; then
            echo '[]'
        fi
    }
    export -f docker
    run _require_single_project
    [ "$status" -ne 0 ]
    [[ "$output" == *"No running devbox session"* ]]
}

@test "require_single_project returns name when exactly one" {
    docker() {
        if [[ "$*" == *"compose ls"* ]]; then
            echo '[{"Name":"devbox-abc123","Status":"running(2)"}]'
        fi
    }
    export -f docker
    run _require_single_project
    [ "$status" -eq 0 ]
    [ "$output" = "devbox-abc123" ]
}

@test "require_single_project errors when multiple running" {
    docker() {
        if [[ "$*" == *"compose ls"* ]]; then
            printf '{"Name":"devbox-abc123","Status":"running(2)"}\n{"Name":"devbox-def456","Status":"running(1)"}\n'
        fi
    }
    export -f docker
    run _require_single_project
    [ "$status" -ne 0 ]
    [[ "$output" == *"Multiple devbox sessions"* ]]
}
