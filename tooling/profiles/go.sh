#!/usr/bin/env bash
# devbox profile: Go
#
# Installs Go toolchain and common development tools.
# Idempotent — safe to run multiple times.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# Pinned tool versions. Bump quarterly.
GOPLS_VERSION="v0.18.1"
GOLANGCI_LINT_VERSION="v1.63.4"
DELVE_VERSION="v1.24.1"

echo "[profile:go] Setting up Go environment..."

# Install Go if not present.
if ! command -v go &>/dev/null; then
    echo "[profile:go] Installing Go..."
    GO_VERSION="1.23.6"
    # Detect architecture from uname for portability.
    case "$(uname -m)" in
        x86_64) ARCH="amd64" ;;
        aarch64 | arm64) ARCH="arm64" ;;
        *)
            echo "[profile:go] WARNING: Unknown architecture '$(uname -m)', defaulting to amd64"
            ARCH="amd64"
            ;;
    esac
    OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.${OS}-${ARCH}.tar.gz" | tar -C /usr/local -xz
    export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
    # Append to zshrc (container default shell) if not already present.
    grep -qF '/usr/local/go/bin' "$HOME/.zshrc" 2>/dev/null \
        || echo 'export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"' >>"$HOME/.zshrc"
else
    echo "[profile:go] Go already installed."
fi

export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"

# Common Go tools.
echo "[profile:go] Installing Go tools..."
_warn_on_fail "gopls" go install "golang.org/x/tools/gopls@${GOPLS_VERSION}"
_warn_on_fail "golangci-lint" go install "github.com/golangci/golangci-lint/cmd/golangci-lint@${GOLANGCI_LINT_VERSION}"
_warn_on_fail "delve" go install "github.com/go-delve/delve/cmd/dlv@${DELVE_VERSION}"

echo "[profile:go] Go profile complete."
go version
