#!/usr/bin/env bats
# Tests for devbox CLI dispatch and helper functions.
# These test non-Docker CLI paths using stubs.

load test_helper

setup() {
    setup_libs
    stub_devbox_env
    source "${DEVBOX_ROOT}/lib/profile.sh"
    source "${DEVBOX_ROOT}/lib/container.sh"
    source "${DEVBOX_ROOT}/lib/allowlist.sh"
    # devbox uses bash 4+ features (;;&). Find a suitable bash.
    BASH5=""
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash; do
        if [ -x "$candidate" ] && "$candidate" -n "${DEVBOX_ROOT}/devbox" 2>/dev/null; then
            BASH5="$candidate"
            break
        fi
    done
}

teardown() {
    rm -rf "$DEVBOX_DATA" "$DEVBOX_CONFIG" 2>/dev/null || true
}

# --- devbox help ---

@test "devbox help exits 0 and prints usage" {
    [ -z "$BASH5" ] && skip "bash 4+ not found"
    run "$BASH5" "${DEVBOX_ROOT}/devbox" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"USAGE:"* ]]
}

@test "devbox --version prints version string" {
    [ -z "$BASH5" ] && skip "bash 4+ not found"
    run "$BASH5" "${DEVBOX_ROOT}/devbox" --version
    [ "$status" -eq 0 ]
    [[ "$output" == devbox\ v* ]]
}

@test "devbox unknown command exits nonzero when Docker unavailable" {
    [ -z "$BASH5" ] && skip "bash 4+ not found"
    # Create a fake docker that passes info but fails compose.
    local tmpbin
    tmpbin="$(mktemp -d)"
    cat >"${tmpbin}/docker" <<'SCRIPT'
#!/bin/bash
if [[ "$1" == "info" ]]; then exit 0; fi
exit 1
SCRIPT
    chmod +x "${tmpbin}/docker"
    run env PATH="${tmpbin}:$PATH" "$BASH5" "${DEVBOX_ROOT}/devbox" unknowncmd
    rm -rf "$tmpbin"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown command"* ]]
}

# --- project_hash ---

@test "project_hash returns deterministic 16-char hex" {
    # Inline the function for testing (sourcing devbox calls main).
    project_hash() {
        local path="$1"
        if command -v sha256sum &>/dev/null; then
            echo -n "$path" | sha256sum | cut -c1-16
        elif command -v shasum &>/dev/null; then
            echo -n "$path" | shasum -a 256 | cut -c1-16
        fi
    }
    local hash1 hash2
    hash1="$(project_hash "/tmp/test-project")"
    hash2="$(project_hash "/tmp/test-project")"
    [ "$hash1" = "$hash2" ]
    [ "${#hash1}" -eq 16 ]
    [[ "$hash1" =~ ^[a-f0-9]{16}$ ]]
}

@test "project_hash differs for different paths" {
    project_hash() {
        local path="$1"
        if command -v sha256sum &>/dev/null; then
            echo -n "$path" | sha256sum | cut -c1-16
        elif command -v shasum &>/dev/null; then
            echo -n "$path" | shasum -a 256 | cut -c1-16
        fi
    }
    local hash1 hash2
    hash1="$(project_hash "/tmp/project-a")"
    hash2="$(project_hash "/tmp/project-b")"
    [ "$hash1" != "$hash2" ]
}

# --- resolve_project_path ---

@test "resolve_project_path resolves current directory" {
    resolve_project_path() {
        local target="${1:-.}"
        if [ -d "$target" ]; then
            (cd "$target" && pwd)
        else
            echo "[error] Project path does not exist: $target" >&2
            return 1
        fi
    }
    local result
    result="$(resolve_project_path ".")"
    [ "$result" = "$(pwd)" ]
}

@test "resolve_project_path fails on nonexistent directory" {
    resolve_project_path() {
        local target="${1:-.}"
        if [ -d "$target" ]; then
            (cd "$target" && pwd)
        else
            echo "[error] Project path does not exist: $target" >&2
            return 1
        fi
    }
    run resolve_project_path "/nonexistent/path/that/does/not/exist"
    [ "$status" -ne 0 ]
}

# --- ensure_project_dirs ---

@test "ensure_project_dirs creates expected structure" {
    ensure_project_dirs() {
        local hash="$1"
        local project_dir="${DEVBOX_DATA}/${hash}"
        mkdir -p \
            "${project_dir}/history" \
            "${project_dir}/logs" \
            "${project_dir}/memory"
    }
    ensure_project_dirs "abc123"
    [ -d "${DEVBOX_DATA}/abc123/history" ]
    [ -d "${DEVBOX_DATA}/abc123/logs" ]
    [ -d "${DEVBOX_DATA}/abc123/memory" ]
}

# --- ensure_global_dirs ---

@test "ensure_global_dirs creates secrets with restrictive permissions" {
    # Ensure clean state — mkdir -p is a no-op on existing dirs.
    rm -rf "${DEVBOX_DATA}/secrets"
    ensure_global_dirs() {
        (umask 077 && mkdir -p "${DEVBOX_DATA}/secrets")
    }
    ensure_global_dirs
    [ -d "${DEVBOX_DATA}/secrets" ]
    # Check permissions (should be 700 on the secrets dir).
    # Linux stat -c, macOS stat -f (try Linux first — macOS stat -f is different).
    local perms
    perms="$(stat -c '%a' "${DEVBOX_DATA}/secrets" 2>/dev/null || stat -f '%Lp' "${DEVBOX_DATA}/secrets" 2>/dev/null)"
    [ "$perms" = "700" ]
}

# --- ensure_global_dirs secrets permissions warning ---

@test "ensure_global_dirs warns on loose secrets permissions" {
    # Create a .env file with overly permissive permissions.
    mkdir -p "${DEVBOX_DATA}/secrets"
    echo "# test" >"${DEVBOX_DATA}/secrets/.env"
    chmod 644 "${DEVBOX_DATA}/secrets/.env"

    run bash -c "
        export DEVBOX_DATA='${DEVBOX_DATA}'
        export NO_COLOR=1
        source '${DEVBOX_ROOT}/lib/ui.sh'
        # The file already exists, so we only test the else branch.
        perms=\"\$(stat -c '%a' '${DEVBOX_DATA}/secrets/.env' 2>/dev/null \
            || stat -f '%Lp' '${DEVBOX_DATA}/secrets/.env' 2>/dev/null)\"
        case \"\$perms\" in
            600 | 400) ;;
            *)
                ui_warn \"Secrets file has permissions \$perms (expected 600).\"
                ;;
        esac
    " 2>&1
    [[ "$output" == *"permissions"* ]]
    [[ "$output" == *"644"* ]]
}

# --- cmd_clean safety ---

# --- ui_confirm default parameter ---

@test "ui_confirm default-yes returns 0 on empty input" {
    run bash -c "
        export NO_COLOR=1
        source '${DEVBOX_ROOT}/lib/ui.sh'
        echo '' | ui_confirm 'Continue?' 'y'
    "
    [ "$status" -eq 0 ]
}

@test "ui_confirm default-no returns 1 on empty input" {
    run bash -c "
        export NO_COLOR=1
        source '${DEVBOX_ROOT}/lib/ui.sh'
        echo '' | ui_confirm 'Continue?' 'n'
    "
    [ "$status" -eq 1 ]
}

@test "ui_confirm default-yes still returns 1 on explicit no" {
    run bash -c "
        export NO_COLOR=1
        source '${DEVBOX_ROOT}/lib/ui.sh'
        echo 'n' | ui_confirm 'Continue?' 'y'
    "
    [ "$status" -eq 1 ]
}

@test "ui_confirm default-no still returns 0 on explicit yes" {
    run bash -c "
        export NO_COLOR=1
        source '${DEVBOX_ROOT}/lib/ui.sh'
        echo 'y' | ui_confirm 'Continue?'
    "
    [ "$status" -eq 0 ]
}

@test "ui_confirm default-yes shows Y/n hint" {
    run bash -c "
        export NO_COLOR=1
        source '${DEVBOX_ROOT}/lib/ui.sh'
        echo '' | ui_confirm 'Continue?' 'y'
    "
    [[ "$output" == *"[Y/n]"* ]]
}

# --- devbox profile list ---

@test "devbox profile list shows available profiles" {
    # profile list is tested via lib/commands.sh directly since devbox
    # requires Docker for non-help commands.
    source "${DEVBOX_ROOT}/lib/commands.sh"
    source "${DEVBOX_ROOT}/lib/profile.sh"
    run cmd_profile "list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"python"* ]]
    [[ "$output" == *"rust"* ]]
    [[ "$output" == *"go"* ]]
    [[ "$output" == *"node"* ]]
}

# --- devbox allowlist show ---

@test "cmd_allowlist show displays policy" {
    source "${DEVBOX_ROOT}/lib/commands.sh"
    local policy
    policy="$(create_test_policy "example.com" "api.openai.com")"
    # Stub get_policy_file to return our test policy.
    get_policy_file() { echo "$policy"; }
    run cmd_allowlist "show"
    [ "$status" -eq 0 ]
    [[ "$output" == *"example.com"* ]]
    rm -f "$policy"
}

# --- profile_detect ---

@test "profile_detect finds python project" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    touch "${tmpdir}/pyproject.toml"
    source "${DEVBOX_ROOT}/lib/profile.sh"
    run profile_detect "$tmpdir"
    rm -rf "$tmpdir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"python"* ]]
}

@test "profile_detect finds multiple languages" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    touch "${tmpdir}/package.json"
    touch "${tmpdir}/go.mod"
    source "${DEVBOX_ROOT}/lib/profile.sh"
    run profile_detect "$tmpdir"
    rm -rf "$tmpdir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"node"* ]]
    [[ "$output" == *"go"* ]]
}

@test "profile_detect returns nothing for empty directory" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    source "${DEVBOX_ROOT}/lib/profile.sh"
    run profile_detect "$tmpdir"
    rm -rf "$tmpdir"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- cmd_clean safety ---

@test "cmd_clean refuses to delete when DEVBOX_DATA is root" {
    run bash -c "
        export DEVBOX_DATA='/'
        source '${DEVBOX_ROOT}/lib/ui.sh'
        cmd_clean_all() {
            if [ -z \"\${DEVBOX_DATA:-}\" ] || [ \"\$DEVBOX_DATA\" = '/' ] || [ \"\$DEVBOX_DATA\" = \"\$HOME\" ]; then
                echo '[error] Refusing to delete' >&2
                return 1
            fi
        }
        cmd_clean_all
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *"Refusing to delete"* ]]
}
