#!/usr/bin/env bats
# Tests for lib/mount.sh — per-project volume mount management.

load test_helper

setup() {
    setup_libs
    stub_devbox_env
    source "${DEVBOX_ROOT}/lib/mount.sh"

    # Helpers expected by mount.sh
    project_hash() { echo "abcdef1234567890"; }
    resolve_project_path() { echo "/tmp/test-project"; }
    _hash_for_project_name() { return 1; }
    export -f project_hash resolve_project_path _hash_for_project_name

    # Create working directories
    OVERRIDE_FILE="${DEVBOX_DATA}/abcdef1234567890/compose.override.yml"
    mkdir -p "$(dirname "$OVERRIDE_FILE")"

    # Create a host path under $HOME for validation
    TEST_HOST_DIR="$(mktemp -d "${HOME}/devbox-mount-test-XXXX")"
}

teardown() {
    [ -d "${TEST_HOST_DIR:-}" ] && rm -rf "$TEST_HOST_DIR"
}

# --- _validate_mount_paths ---

@test "validate_mount_paths accepts valid paths" {
    run _validate_mount_paths "$TEST_HOST_DIR" "/mnt/data"
    [ "$status" -eq 0 ]
}

@test "validate_mount_paths rejects nonexistent host path" {
    run _validate_mount_paths "/nonexistent/dir" "/mnt/data"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not exist"* ]]
}

@test "validate_mount_paths rejects relative container path" {
    run _validate_mount_paths "$TEST_HOST_DIR" "relative/path"
    [ "$status" -ne 0 ]
    [[ "$output" == *"must be absolute"* ]]
}

@test "validate_mount_paths rejects blocked container path /workspace" {
    run _validate_mount_paths "$TEST_HOST_DIR" "/workspace"
    [ "$status" -ne 0 ]
    [[ "$output" == *"reserved"* ]]
}

@test "validate_mount_paths rejects subpath of blocked container path" {
    run _validate_mount_paths "$TEST_HOST_DIR" "/workspace/subdir"
    [ "$status" -ne 0 ]
    [[ "$output" == *"reserved"* ]]
}

@test "validate_mount_paths rejects blocked host path .ssh" {
    local ssh_dir="${HOME}/.ssh"
    mkdir -p "$ssh_dir" 2>/dev/null || true
    if [ -d "$ssh_dir" ]; then
        run _validate_mount_paths "$ssh_dir" "/mnt/keys"
        [ "$status" -ne 0 ]
        [[ "$output" == *"sensitive"* ]]
    else
        skip ".ssh directory does not exist"
    fi
}

@test "validate_mount_paths rejects single quote in path" {
    run _validate_mount_paths "$TEST_HOST_DIR" "/mnt/it's-bad"
    [ "$status" -ne 0 ]
    [[ "$output" == *"single quotes"* ]]
}

# --- _write_compose_override and _parse_mounts ---

@test "write_compose_override creates valid YAML" {
    _write_compose_override "$OVERRIDE_FILE" "/host/a:/container/a:rw"
    [ -f "$OVERRIDE_FILE" ]
    run grep "volumes:" "$OVERRIDE_FILE"
    [ "$status" -eq 0 ]
    run grep "/host/a:/container/a:rw" "$OVERRIDE_FILE"
    [ "$status" -eq 0 ]
}

@test "write_compose_override removes file when no mounts" {
    echo "placeholder" > "$OVERRIDE_FILE"
    _write_compose_override "$OVERRIDE_FILE"
    [ ! -f "$OVERRIDE_FILE" ]
}

@test "parse_mounts returns entries from override file" {
    _write_compose_override "$OVERRIDE_FILE" "/host/a:/container/a:rw" "/host/b:/container/b:ro"
    run _parse_mounts "$OVERRIDE_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/host/a:/container/a:rw"* ]]
    [[ "$output" == *"/host/b:/container/b:ro"* ]]
}

@test "parse_mounts returns nothing for missing file" {
    run _parse_mounts "/nonexistent/file.yml"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- _validate_compose_override ---

@test "validate_compose_override accepts valid file" {
    _write_compose_override "$OVERRIDE_FILE" "/host/a:/container/a:rw"
    run _validate_compose_override "$OVERRIDE_FILE"
    [ "$status" -eq 0 ]
}

@test "validate_compose_override rejects file with non-volume keys" {
    cat > "$OVERRIDE_FILE" <<'EOF'
services:
  agent:
    volumes:
      - '/host/a:/container/a:rw'
    environment:
      - EVIL=true
EOF
    run _validate_compose_override "$OVERRIDE_FILE"
    [ "$status" -ne 0 ]
}

# --- mount_add ---

@test "mount_add creates override with mount" {
    run mount_add "$OVERRIDE_FILE" "$TEST_HOST_DIR" "/mnt/data" "rw"
    [ "$status" -eq 0 ]
    [ -f "$OVERRIDE_FILE" ]
    run grep "/mnt/data" "$OVERRIDE_FILE"
    [ "$status" -eq 0 ]
}

@test "mount_add rejects invalid mode" {
    run mount_add "$OVERRIDE_FILE" "$TEST_HOST_DIR" "/mnt/data" "exec"
    [ "$status" -ne 0 ]
    [[ "$output" == *"rw"* ]]
}

@test "mount_add rejects duplicate container path" {
    mount_add "$OVERRIDE_FILE" "$TEST_HOST_DIR" "/mnt/data" "rw"
    run mount_add "$OVERRIDE_FILE" "$TEST_HOST_DIR" "/mnt/data" "ro"
    [ "$status" -ne 0 ]
    [[ "$output" == *"already exists"* ]]
}

# --- mount_remove ---

@test "mount_remove deletes existing mount" {
    mount_add "$OVERRIDE_FILE" "$TEST_HOST_DIR" "/mnt/data" "rw"
    run mount_remove "$OVERRIDE_FILE" "/mnt/data"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Removed"* ]]
}

@test "mount_remove errors on nonexistent mount" {
    mount_add "$OVERRIDE_FILE" "$TEST_HOST_DIR" "/mnt/data" "rw"
    run mount_remove "$OVERRIDE_FILE" "/mnt/other"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No mount found"* ]]
}

# --- mount_list ---

@test "mount_list shows configured mounts" {
    mount_add "$OVERRIDE_FILE" "$TEST_HOST_DIR" "/mnt/data" "rw"
    run mount_list "$OVERRIDE_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/mnt/data"* ]]
    [[ "$output" == *"rw"* ]]
}

@test "mount_list shows message when no mounts" {
    run mount_list "$OVERRIDE_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No custom mounts"* ]]
}

# --- cmd_mount dispatcher ---
# cmd_mount is in commands.sh and wraps the mount functions above.

@test "cmd_mount add rejects missing arguments" {
    source "${DEVBOX_ROOT}/lib/commands.sh"
    run cmd_mount "add"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage:"* ]]
}

# cmd_mount add with :ro/:rw suffix requires a real project in ~/.devbox/.
# Covered by functional testing (devbox mount add <name> /path /mnt:ro).

@test "cmd_mount add rejects invalid suffix" {
    source "${DEVBOX_ROOT}/lib/commands.sh"
    run cmd_mount "add" "testproj" "$TEST_HOST_DIR" "/mnt/data:exec"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid mount suffix"* ]]
}

@test "cmd_mount remove rejects missing arguments" {
    source "${DEVBOX_ROOT}/lib/commands.sh"
    run cmd_mount "remove" ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "cmd_mount list works without project name" {
    source "${DEVBOX_ROOT}/lib/commands.sh"
    run cmd_mount "list"
    [ "$status" -eq 0 ]
}

@test "cmd_mount unknown subcommand fails" {
    source "${DEVBOX_ROOT}/lib/commands.sh"
    run cmd_mount "destroy"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown mount command"* ]]
}

@test "cmd_mount help shows usage" {
    source "${DEVBOX_ROOT}/lib/commands.sh"
    run cmd_mount "help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: devbox mount"* ]]
}

@test "cmd_mount with no subcommand lists mounts" {
    source "${DEVBOX_ROOT}/lib/commands.sh"
    run cmd_mount ""
    [ "$status" -eq 0 ]
}

# cmd_mount add tilde expansion requires a real project in ~/.devbox/.
# Covered by functional testing.
@test "placeholder_tilde_expansion" {
    skip "requires real project setup"
}
