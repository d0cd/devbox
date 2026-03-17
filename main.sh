#!/usr/bin/env bash
# devbox installer — sets up devbox on the host system.
#
# Usage:
#   curl -fsSL <url>/main.sh | bash
#   # or
#   ./main.sh
set -euo pipefail

INSTALL_DIR="${DEVBOX_INSTALL_DIR:-$HOME/.local/share/devbox}"
BIN_DIR="${HOME}/.local/bin"

# Minimal UI helpers for the installer (standalone — cannot source lib/ui.sh).
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ] && command -v tput &>/dev/null; then
    _RED="$(tput setaf 1)"
    _GREEN="$(tput setaf 2)"
    _YELLOW="$(tput setaf 3)"
    _CYAN="$(tput setaf 6)"
    _BOLD="$(tput bold)"
    _RESET="$(tput sgr0)"
else
    _RED=""
    _GREEN=""
    _YELLOW=""
    _CYAN=""
    _BOLD=""
    _RESET=""
fi
ui_header() {
    echo ""
    echo "${_BOLD}${_CYAN}=== $* ===${_RESET}"
    echo ""
}
ui_info() { echo "${_GREEN}[info]${_RESET} $*"; }
ui_warn() { echo "${_YELLOW}[warn]${_RESET} $*" >&2; }
ui_error() { echo "${_RED}[error]${_RESET} $*" >&2; }

ui_header "devbox installer"

# --- Dependency checks ---
check_dep() {
    if ! command -v "$1" &>/dev/null; then
        ui_error "$1 is required but not installed."
        exit 1
    fi
}

check_dep docker
check_dep git

# Check for Docker Compose v2.
if ! docker compose version &>/dev/null; then
    ui_error "Docker Compose v2 is required (docker compose, not docker-compose)."
    exit 1
fi

# Check Docker daemon is actually running (not just installed).
if ! docker info &>/dev/null; then
    ui_error "Docker daemon is not running. Start Docker and try again."
    exit 1
fi

# --- Install or update ---
if [ -d "$INSTALL_DIR" ]; then
    ui_info "Updating existing installation at $INSTALL_DIR..."
    cd "$INSTALL_DIR"
    if ! git pull --ff-only; then
        ui_error "Failed to update. Your local copy may have diverged."
        ui_info "Fix manually: cd $INSTALL_DIR && git stash && git pull --ff-only"
        exit 1
    fi
else
    ui_info "Cloning devbox to $INSTALL_DIR..."
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone https://github.com/d0cd/devbox.git "$INSTALL_DIR"
fi

# --- Symlink ---
mkdir -p "$BIN_DIR"
ln -sf "${INSTALL_DIR}/devbox" "${BIN_DIR}/devbox"
chmod +x "${INSTALL_DIR}/devbox"

# --- Global directories ---
(
    umask 077
    mkdir -p "$HOME/.devbox/secrets"
)
mkdir -p "$HOME/.config/devbox"

# --- Build images ---
ui_info "Building devbox container images (this may take a few minutes)..."
cd "$INSTALL_DIR"
if ! docker compose build; then
    ui_error "Docker image build failed."
    ui_info "Common fixes:"
    ui_info "  - Check your internet connection (images need to download packages)"
    ui_info "  - Free disk space: docker system prune"
    ui_info "  - Retry: cd $INSTALL_DIR && docker compose build"
    exit 1
fi

ui_header "devbox installed successfully"

# --- Check PATH ---
if ! echo "$PATH" | tr ':' '\n' | grep -q "^${BIN_DIR}$"; then
    ui_warn "${BIN_DIR} is not in your PATH."
    ui_info "Add this to your shell profile:"
    ui_info "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
    ui_info "Then run 'devbox' in any project directory to start."
else
    ui_info "Run 'devbox' in any project directory to start."
fi

# --- Shell completion ---
ui_info "Enable tab completion with:"
ui_info "  source <(devbox completions)"
