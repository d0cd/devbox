#!/usr/bin/env bash
# devbox profile: Node.js
#
# VARIANTS: bun
# VARIANT_bun: Bun runtime alongside Node.js
#
# Ensures Node.js LTS is available and installs pnpm and common dev tools.
# Idempotent — safe to run multiple times.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# Pinned tool versions (major). Bump quarterly.
PNPM_VERSION="9"
TYPESCRIPT_VERSION="5"
TSX_VERSION="4"
ESLINT_VERSION="9"
PRETTIER_VERSION="3"

echo "[profile:node] Setting up Node.js environment..."

# Install pnpm if not present.
if ! command -v pnpm &>/dev/null; then
    echo "[profile:node] Installing pnpm..."
    npm install -g "pnpm@${PNPM_VERSION}"
else
    echo "[profile:node] pnpm already installed."
fi

# Common dev tools.
echo "[profile:node] Installing dev tools..."
_warn_on_fail "typescript" npm install -g "typescript@${TYPESCRIPT_VERSION}"
_warn_on_fail "tsx" npm install -g "tsx@${TSX_VERSION}"
_warn_on_fail "eslint" npm install -g "eslint@${ESLINT_VERSION}"
_warn_on_fail "prettier" npm install -g "prettier@${PRETTIER_VERSION}"

# Bun variant: install Bun runtime.
if [ "${PROFILE_VARIANT:-}" = "bun" ]; then
    echo "[profile:node] Installing Bun runtime..."
    curl -fsSL https://bun.sh/install | bash
    export PATH="$HOME/.bun/bin:$PATH"
fi

echo "[profile:node] Node.js profile complete."
node --version
npm --version
pnpm --version 2>/dev/null || true
