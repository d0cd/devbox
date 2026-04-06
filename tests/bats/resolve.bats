#!/usr/bin/env bats
# Tests for project resolution and hash extraction functions.
#   _resolve_project_arg — resolves name, path, or empty arg to project path
#   _hash_from_compose_project — extracts 16-char hash from compose project name
#   _hash_for_project_name — looks up hash by project name
#   _project_name_for_hash — reads stored project name for a hash

load test_helper

setup() {
    setup_libs
    stub_devbox_env
    source "${DEVBOX_ROOT}/lib/commands.sh"
    source "${DEVBOX_ROOT}/lib/container.sh"
}

teardown() {
    rm -rf "$DEVBOX_DATA" "$DEVBOX_CONFIG" 2>/dev/null || true
}

# --- _hash_from_compose_project ---

@test "hash_from_compose_project extracts hash from new format (devbox-name-hash)" {
    run _hash_from_compose_project "devbox-myproject-abcdef1234567890"
    [ "$status" -eq 0 ]
    [ "$output" = "abcdef1234567890" ]
}

@test "hash_from_compose_project extracts hash from old format (devbox-hash)" {
    run _hash_from_compose_project "devbox-abcdef1234567890"
    [ "$status" -eq 0 ]
    [ "$output" = "abcdef1234567890" ]
}

@test "hash_from_compose_project handles hyphenated project name" {
    run _hash_from_compose_project "devbox-my-cool-project-abcdef1234567890"
    [ "$status" -eq 0 ]
    [ "$output" = "abcdef1234567890" ]
}

@test "hash_from_compose_project returns last 16 chars regardless of prefix" {
    run _hash_from_compose_project "anything-0123456789abcdef"
    [ "$status" -eq 0 ]
    [ "$output" = "0123456789abcdef" ]
}

# --- _project_name_for_hash ---

@test "project_name_for_hash reads .project_name file" {
    local hash="abcdef1234567890"
    mkdir -p "${DEVBOX_DATA}/${hash}"
    echo "my-project" > "${DEVBOX_DATA}/${hash}/.project_name"
    run _project_name_for_hash "$hash"
    [ "$status" -eq 0 ]
    [ "$output" = "my-project" ]
}

@test "project_name_for_hash falls back to basename of .project_path" {
    local hash="abcdef1234567890"
    mkdir -p "${DEVBOX_DATA}/${hash}"
    echo "/home/user/projects/fallback-proj" > "${DEVBOX_DATA}/${hash}/.project_path"
    run _project_name_for_hash "$hash"
    [ "$status" -eq 0 ]
    [ "$output" = "fallback-proj" ]
}

@test "project_name_for_hash falls back to hash when no files exist" {
    local hash="abcdef1234567890"
    mkdir -p "${DEVBOX_DATA}/${hash}"
    run _project_name_for_hash "$hash"
    [ "$status" -eq 0 ]
    [ "$output" = "$hash" ]
}

# --- _hash_for_project_name ---

@test "hash_for_project_name finds matching project" {
    local hash="abcdef1234567890"
    mkdir -p "${DEVBOX_DATA}/${hash}"
    echo "ralph" > "${DEVBOX_DATA}/${hash}/.project_name"
    run _hash_for_project_name "ralph"
    [ "$status" -eq 0 ]
    [ "$output" = "$hash" ]
}

@test "hash_for_project_name returns 1 when not found" {
    run _hash_for_project_name "nonexistent"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "hash_for_project_name skips non-hash directories" {
    # Create directories that look like non-hash entries (secrets, claude).
    mkdir -p "${DEVBOX_DATA}/secrets"
    echo "secrets" > "${DEVBOX_DATA}/secrets/.project_name"
    mkdir -p "${DEVBOX_DATA}/claude"
    echo "claude" > "${DEVBOX_DATA}/claude/.project_name"
    run _hash_for_project_name "secrets"
    [ "$status" -ne 0 ]
}

@test "hash_for_project_name matches via .project_path basename fallback" {
    local hash="1234567890abcdef"
    mkdir -p "${DEVBOX_DATA}/${hash}"
    echo "/home/user/projects/my-app" > "${DEVBOX_DATA}/${hash}/.project_path"
    # No .project_name file — should fall back to basename "my-app".
    run _hash_for_project_name "my-app"
    [ "$status" -eq 0 ]
    [ "$output" = "$hash" ]
}

# --- _resolve_project_arg ---

@test "resolve_project_arg resolves empty arg to current directory" {
    run _resolve_project_arg ""
    [ "$status" -eq 0 ]
    [ "$output" = "$(pwd)" ]
}

@test "resolve_project_arg resolves valid directory path" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    run _resolve_project_arg "$tmpdir"
    [ "$status" -eq 0 ]
    [ "$output" = "$tmpdir" ]
    rm -rf "$tmpdir"
}

@test "resolve_project_arg resolves project by name" {
    local hash="abcdef1234567890"
    local tmpdir
    tmpdir="$(mktemp -d)"
    mkdir -p "${DEVBOX_DATA}/${hash}"
    echo "my-proj" > "${DEVBOX_DATA}/${hash}/.project_name"
    echo "$tmpdir" > "${DEVBOX_DATA}/${hash}/.project_path"
    run _resolve_project_arg "my-proj"
    [ "$status" -eq 0 ]
    [ "$output" = "$tmpdir" ]
    rm -rf "$tmpdir"
}

@test "resolve_project_arg errors on name with deleted directory" {
    local hash="abcdef1234567890"
    mkdir -p "${DEVBOX_DATA}/${hash}"
    echo "stale-proj" > "${DEVBOX_DATA}/${hash}/.project_name"
    echo "/nonexistent/deleted/path" > "${DEVBOX_DATA}/${hash}/.project_path"
    run _resolve_project_arg "stale-proj"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no longer exists"* ]]
}

@test "resolve_project_arg errors on unknown name" {
    run _resolve_project_arg "unknown-project-name"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Not a directory or known project"* ]]
}

@test "resolve_project_arg errors on nonexistent path" {
    run _resolve_project_arg "/nonexistent/path/that/does/not/exist"
    [ "$status" -ne 0 ]
}
