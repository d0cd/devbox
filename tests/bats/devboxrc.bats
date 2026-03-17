#!/usr/bin/env bats
# Tests for .devboxrc config loading.

load test_helper

setup() {
    setup_libs
    stub_devbox_env
    # CIDR_PATTERN is normally defined by lib/firewall.sh (sourced by devbox).
    # Define it here since firewall.sh requires iptables (unavailable on host).
    CIDR_PATTERN='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$'
    export CIDR_PATTERN
    source "${DEVBOX_ROOT}/lib/commands.sh"
}

teardown() {
    rm -rf "$DEVBOX_DATA" "$DEVBOX_CONFIG" 2>/dev/null || true
}

@test "load_devboxrc sets reload interval from file" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "DEVBOX_RELOAD_INTERVAL=45" >"${tmpdir}/.devboxrc"
    unset DEVBOX_RELOAD_INTERVAL
    _load_devboxrc "$tmpdir"
    [ "$DEVBOX_RELOAD_INTERVAL" = "45" ]
    rm -rf "$tmpdir"
}

@test "load_devboxrc does not override existing env var" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "DEVBOX_RELOAD_INTERVAL=45" >"${tmpdir}/.devboxrc"
    export DEVBOX_RELOAD_INTERVAL=99
    _load_devboxrc "$tmpdir"
    [ "$DEVBOX_RELOAD_INTERVAL" = "99" ]
    rm -rf "$tmpdir"
}

@test "load_devboxrc skips unknown variables" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "UNKNOWN_VAR=bad" >"${tmpdir}/.devboxrc"
    run _load_devboxrc "$tmpdir"
    [ "$status" -eq 0 ]
    [ -z "${UNKNOWN_VAR:-}" ]
    rm -rf "$tmpdir"
}

@test "load_devboxrc rejects non-numeric reload interval" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "DEVBOX_RELOAD_INTERVAL=notanumber" >"${tmpdir}/.devboxrc"
    unset DEVBOX_RELOAD_INTERVAL
    _load_devboxrc "$tmpdir"
    [ -z "${DEVBOX_RELOAD_INTERVAL:-}" ]
    rm -rf "$tmpdir"
}

@test "load_devboxrc skips comments and blank lines" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    printf '# comment\n\nDEVBOX_RELOAD_INTERVAL=45\n' >"${tmpdir}/.devboxrc"
    unset DEVBOX_RELOAD_INTERVAL
    _load_devboxrc "$tmpdir"
    [ "$DEVBOX_RELOAD_INTERVAL" = "45" ]
    rm -rf "$tmpdir"
}

@test "load_devboxrc validates CIDR for bridge subnet" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "DEVBOX_BRIDGE_SUBNET=not-a-cidr" >"${tmpdir}/.devboxrc"
    unset DEVBOX_BRIDGE_SUBNET
    _load_devboxrc "$tmpdir"
    [ -z "${DEVBOX_BRIDGE_SUBNET:-}" ]
    rm -rf "$tmpdir"
}

@test "load_devboxrc accepts valid CIDR for bridge subnet" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "DEVBOX_BRIDGE_SUBNET=10.0.0.0/24" >"${tmpdir}/.devboxrc"
    unset DEVBOX_BRIDGE_SUBNET
    _load_devboxrc "$tmpdir"
    [ "$DEVBOX_BRIDGE_SUBNET" = "10.0.0.0/24" ]
    rm -rf "$tmpdir"
}

@test "load_devboxrc is no-op when file missing" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    run _load_devboxrc "$tmpdir"
    [ "$status" -eq 0 ]
    rm -rf "$tmpdir"
}

@test "load_devboxrc rejects nonexistent path and non-URL for private configs" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "DEVBOX_PRIVATE_CONFIGS=not-a-url-or-path" >"${tmpdir}/.devboxrc"
    unset DEVBOX_PRIVATE_CONFIGS
    _load_devboxrc "$tmpdir"
    [ -z "${DEVBOX_PRIVATE_CONFIGS:-}" ]
    rm -rf "$tmpdir"
}

@test "load_devboxrc accepts valid git URL for private configs" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "DEVBOX_PRIVATE_CONFIGS=git@github.com:user/repo.git" >"${tmpdir}/.devboxrc"
    unset DEVBOX_PRIVATE_CONFIGS
    _load_devboxrc "$tmpdir"
    [ "$DEVBOX_PRIVATE_CONFIGS" = "git@github.com:user/repo.git" ]
    rm -rf "$tmpdir"
}

@test "load_devboxrc accepts local directory path for private configs" {
    local tmpdir configdir
    tmpdir="$(mktemp -d)"
    configdir="$(mktemp -d)"
    echo "DEVBOX_PRIVATE_CONFIGS=${configdir}" >"${tmpdir}/.devboxrc"
    unset DEVBOX_PRIVATE_CONFIGS
    _load_devboxrc "$tmpdir"
    [ "$DEVBOX_PRIVATE_CONFIGS" = "${configdir}" ]
    rm -rf "$tmpdir" "$configdir"
}

@test "load_devboxrc sets reload interval with different value" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "DEVBOX_RELOAD_INTERVAL=60" >"${tmpdir}/.devboxrc"
    unset DEVBOX_RELOAD_INTERVAL
    _load_devboxrc "$tmpdir"
    [ "$DEVBOX_RELOAD_INTERVAL" = "60" ]
    rm -rf "$tmpdir"
}

@test "load_devboxrc accepts valid memory value" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "DEVBOX_MEMORY=12G" >"${tmpdir}/.devboxrc"
    unset DEVBOX_MEMORY
    _load_devboxrc "$tmpdir"
    [ "$DEVBOX_MEMORY" = "12G" ]
    rm -rf "$tmpdir"
}

@test "load_devboxrc accepts memory in megabytes" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "DEVBOX_MEMORY=512M" >"${tmpdir}/.devboxrc"
    unset DEVBOX_MEMORY
    _load_devboxrc "$tmpdir"
    [ "$DEVBOX_MEMORY" = "512M" ]
    rm -rf "$tmpdir"
}

@test "load_devboxrc rejects invalid memory value" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "DEVBOX_MEMORY=lots" >"${tmpdir}/.devboxrc"
    unset DEVBOX_MEMORY
    _load_devboxrc "$tmpdir"
    [ -z "${DEVBOX_MEMORY:-}" ]
    rm -rf "$tmpdir"
}

@test "load_devboxrc accepts valid CPU value" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "DEVBOX_CPUS=4.0" >"${tmpdir}/.devboxrc"
    unset DEVBOX_CPUS
    _load_devboxrc "$tmpdir"
    [ "$DEVBOX_CPUS" = "4.0" ]
    rm -rf "$tmpdir"
}

@test "load_devboxrc accepts integer CPU value" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "DEVBOX_CPUS=2" >"${tmpdir}/.devboxrc"
    unset DEVBOX_CPUS
    _load_devboxrc "$tmpdir"
    [ "$DEVBOX_CPUS" = "2" ]
    rm -rf "$tmpdir"
}

@test "load_devboxrc rejects invalid CPU value" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "DEVBOX_CPUS=many" >"${tmpdir}/.devboxrc"
    unset DEVBOX_CPUS
    _load_devboxrc "$tmpdir"
    [ -z "${DEVBOX_CPUS:-}" ]
    rm -rf "$tmpdir"
}

@test "load_devboxrc rejects invalid syntax lines" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    printf 'this is not valid\nDEVBOX_RELOAD_INTERVAL=30\n' >"${tmpdir}/.devboxrc"
    unset DEVBOX_RELOAD_INTERVAL
    _load_devboxrc "$tmpdir"
    [ "$DEVBOX_RELOAD_INTERVAL" = "30" ]
    rm -rf "$tmpdir"
}
