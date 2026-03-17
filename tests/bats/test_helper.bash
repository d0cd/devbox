#!/usr/bin/env bash
# Shared test helpers for BATS tests.

# Project root relative to test directory.
DEVBOX_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

# Source library modules with mock dependencies.
setup_libs() {
    # Provide minimal ui.sh stubs if needed.
    source "${DEVBOX_ROOT}/lib/ui.sh" 2>/dev/null || {
        ui_info() { echo "[info] $*"; }
        ui_warn() { echo "[warn] $*"; }
        ui_error() { echo "[error] $*" >&2; }
        ui_header() { echo "=== $* ==="; }
        ui_confirm() { return 0; }
    }
    # Library modules set -euo pipefail. BATS does not support set -e —
    # it causes silent test aborts when functions use trap RETURN.
    set +euo pipefail
}

# Create a temporary policy file with given allowed domains.
create_test_policy() {
    local tmpfile
    tmpfile="$(mktemp)"
    echo "version: 1" >"$tmpfile"
    echo "allowed:" >>"$tmpfile"
    for domain in "$@"; do
        echo "  - ${domain}" >>"$tmpfile"
    done
    echo "$tmpfile"
}

# Mock iptables that records calls instead of executing them.
mock_iptables() {
    export IPTABLES_CALLS=""
    iptables() {
        IPTABLES_CALLS="${IPTABLES_CALLS}iptables $*
"
        # Simulate -C (check rule) as success after rules are applied.
        if [[ "$*" == *"-C OUTPUT"* ]]; then
            return 0
        fi
        # Simulate policy check output for integration tests.
        if [[ "$*" == *"-L OUTPUT -n"* ]] && [[ "$*" != *"-v"* ]]; then
            echo "Chain OUTPUT (policy DROP)"
        fi
    }
    export -f iptables
}

# Mock docker command that records calls and returns canned output.
mock_docker() {
    local canned_output="${1:-}"
    export DOCKER_CALLS=""
    export DOCKER_CANNED_OUTPUT="$canned_output"
    docker() {
        DOCKER_CALLS="${DOCKER_CALLS}docker $*
"
        if [ -n "$DOCKER_CANNED_OUTPUT" ]; then
            echo "$DOCKER_CANNED_OUTPUT"
        fi
        return 0
    }
    export -f docker
}

# Set up a temporary devbox environment for testing CLI functions.
stub_devbox_env() {
    DEVBOX_DATA="$(mktemp -d)"
    DEVBOX_CONFIG="$(mktemp -d)"
    export DEVBOX_DATA
    export DEVBOX_CONFIG
    export DEVBOX_ROOT
}
