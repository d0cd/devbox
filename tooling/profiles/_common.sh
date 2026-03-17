#!/usr/bin/env bash
# Shared helpers for devbox profile scripts.
# Sourced by each profile — not executed directly.
set -euo pipefail

# Run a command, printing a warning if it fails but continuing execution.
_warn_on_fail() {
    local label="$1"
    shift
    if ! "$@"; then
        echo "[profile] WARNING: $label failed. Continuing."
    fi
}
