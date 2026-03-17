#!/usr/bin/env bash
# devbox profile: Rust
#
# VARIANTS: wasm
# VARIANT_wasm: wasm-pack, wasm-bindgen-cli, wasm32-unknown-unknown target
#
# Installs Rust toolchain via rustup with common cargo extensions.
# Idempotent — safe to run multiple times.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# Pinned tool versions (major.minor). Bump quarterly.
CARGO_WATCH_VERSION="0.8"
CARGO_EDIT_VERSION="0.13"
CARGO_AUDIT_VERSION="0.21"
CARGO_NEXTEST_VERSION="0.9"

echo "[profile:rust] Installing Rust toolchain..."

# Install rustup if not present.
if ! command -v rustup &>/dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    source "$HOME/.cargo/env"
else
    echo "[profile:rust] rustup already installed, updating..."
    rustup update stable
fi

# Ensure cargo is on PATH for the rest of this script.
export PATH="$HOME/.cargo/bin:$PATH"

# Common cargo extensions.
echo "[profile:rust] Installing cargo tools..."
_warn_on_fail "cargo-watch" cargo install --locked "cargo-watch@${CARGO_WATCH_VERSION}"
_warn_on_fail "cargo-edit" cargo install --locked "cargo-edit@${CARGO_EDIT_VERSION}"
_warn_on_fail "cargo-audit" cargo install --locked "cargo-audit@${CARGO_AUDIT_VERSION}"
_warn_on_fail "cargo-nextest" cargo install --locked "cargo-nextest@${CARGO_NEXTEST_VERSION}"

# Wasm variant: add wasm target and tools.
if [ "${PROFILE_VARIANT:-}" = "wasm" ]; then
    echo "[profile:rust] Installing wasm tooling..."
    rustup target add wasm32-unknown-unknown
    _warn_on_fail "wasm-pack" cargo install --locked wasm-pack
    _warn_on_fail "wasm-bindgen-cli" cargo install --locked wasm-bindgen-cli
fi

echo "[profile:rust] Rust profile complete."
rustc --version
cargo --version
