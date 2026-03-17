#!/usr/bin/env bash
# Agent container entrypoint.
#
# Sets up the firewall, installs the proxy CA certificate, configures
# git identity, and holds the container open as an isolated dev environment.
# Users exec into the running container to use claude, opencode, nvim, etc.
set -euo pipefail

# --- Signal handling ---
cleanup() {
    local pids
    pids="$(jobs -p 2>/dev/null)" || true
    # shellcheck disable=SC2086
    [ -n "$pids" ] && kill $pids 2>/dev/null || true
}
trap cleanup EXIT TERM INT

# --- Detect bridge subnet ---
_detect_bridge_subnet() {
    # Determine the actual Docker bridge subnet for firewall rules.
    if [ -n "${DEVBOX_BRIDGE_SUBNET:-}" ]; then
        echo "[entrypoint] Using configured bridge subnet: $DEVBOX_BRIDGE_SUBNET"
        return
    fi
    # Detect the actual bridge subnet from the routing table.
    # Prefer the non-default route which gives the exact bridge CIDR.
    DEVBOX_BRIDGE_SUBNET="$(ip route | awk '!/default/ && /dev/ && /src/ {print $1; exit}')" || true
    if [ -z "$DEVBOX_BRIDGE_SUBNET" ]; then
        # Fallback: derive from default gateway with a /16 (generous, covers typical Docker bridges).
        DEVBOX_BRIDGE_SUBNET="$(ip route | awk '/default/ {print $3}' | head -1 | sed 's/\.[0-9]*$/\.0\/16/')" || true
    fi
    if [ -z "$DEVBOX_BRIDGE_SUBNET" ]; then
        DEVBOX_BRIDGE_SUBNET="172.17.0.0/16"
        echo "[entrypoint] Could not detect bridge subnet, using fallback: $DEVBOX_BRIDGE_SUBNET"
    else
        echo "[entrypoint] Detected bridge subnet: $DEVBOX_BRIDGE_SUBNET"
    fi
    export DEVBOX_BRIDGE_SUBNET
}
_detect_bridge_subnet

# Source firewall module (defines CIDR_PATTERN and firewall_init).
if [ ! -f /usr/local/lib/devbox/firewall.sh ]; then
    echo "[entrypoint] FATAL: firewall.sh not found at /usr/local/lib/devbox/firewall.sh"
    exit 1
fi
source /usr/local/lib/devbox/firewall.sh

# Validate CIDR format before using in iptables rules.
if [[ ! "$DEVBOX_BRIDGE_SUBNET" =~ $CIDR_PATTERN ]]; then
    echo "[entrypoint] FATAL: Invalid bridge subnet: '$DEVBOX_BRIDGE_SUBNET'"
    echo "[entrypoint] Expected CIDR notation (e.g., 172.18.0.0/16)."
    echo "[entrypoint] Set DEVBOX_BRIDGE_SUBNET or check Docker network config."
    exit 1
fi

# Initialize iptables firewall — mandatory for container safety.
# Retry once after a short delay in case the iptables module isn't loaded yet.
if command -v iptables &>/dev/null; then
    if ! firewall_init; then
        echo "[entrypoint] Firewall init failed, retrying in 2s..."
        sleep 2
        if ! firewall_init; then
            echo "[entrypoint] FATAL: Firewall initialization failed. Refusing to start."
            exit 1
        fi
    fi
else
    echo "[entrypoint] FATAL: iptables not available. Cannot enforce network policy."
    exit 1
fi

# --- Proxy CA Certificate ---
# Install the mitmproxy CA cert so HTTPS inspection works transparently.
# This is mandatory — without it, all HTTPS traffic through the proxy fails.
CA_CERT="/usr/local/share/ca-certificates/mitmproxy-ca-cert.pem"
CA_TIMEOUT=60
CA_ELAPSED=0
while [ ! -f "$CA_CERT" ] && [ "$CA_ELAPSED" -lt "$CA_TIMEOUT" ]; do
    if [ "$CA_ELAPSED" -eq 0 ]; then
        echo "[entrypoint] Waiting for proxy CA certificate..."
    elif [ "$((CA_ELAPSED % 5))" -eq 0 ]; then
        echo "[entrypoint] Still waiting for CA certificate... (${CA_ELAPSED}s/${CA_TIMEOUT}s)"
    fi
    sleep 1
    CA_ELAPSED=$((CA_ELAPSED + 1))
done
if [ ! -f "$CA_CERT" ]; then
    echo "[entrypoint] FATAL: Proxy CA cert not found at $CA_CERT after ${CA_TIMEOUT}s"
    echo "[entrypoint] The proxy sidecar must generate the CA cert before the agent can start."
    exit 1
fi
echo "[entrypoint] Installing proxy CA certificate..."
cp "$CA_CERT" /usr/local/share/ca-certificates/mitmproxy-ca.crt
if ! ca_output="$(update-ca-certificates --fresh 2>&1)"; then
    echo "[entrypoint] FATAL: update-ca-certificates failed"
    echo "$ca_output"
    exit 1
fi
if [ -n "$ca_output" ]; then
    echo "$ca_output" | tail -1
fi
# Also set for Node.js and Python which may not use system store.
export NODE_EXTRA_CA_CERTS="$CA_CERT"
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

# --- Git Identity ---
# Set git identity from environment if provided.
if [ -n "${GIT_AUTHOR_NAME:-}" ]; then
    git config --global user.name "$GIT_AUTHOR_NAME"
fi
if [ -n "${GIT_AUTHOR_EMAIL:-}" ]; then
    git config --global user.email "$GIT_AUTHOR_EMAIL"
fi

# --- OpenCode Configuration ---
# Symlink config files from read-only mount into where OpenCode reads them.
DEVBOX_HOME="/home/devbox"
mkdir -p "${DEVBOX_HOME}/.config/opencode"
if [ -f /devbox/opencode/opencode.json ]; then
    ln -sf /devbox/opencode/opencode.json "${DEVBOX_HOME}/.config/opencode/opencode.json"
fi
if [ -d /devbox/opencode/pal ]; then
    ln -sf /devbox/opencode/pal "${DEVBOX_HOME}/.config/opencode/pal"
fi
# Copy skills/agents/commands (need write access, can't symlink ro mount).
for dir in skills agents commands; do
    if [ -d "/devbox/opencode/${dir}" ]; then
        cp -r "/devbox/opencode/${dir}" "${DEVBOX_HOME}/.config/opencode/${dir}"
    fi
done

# --- Private config overlay ---
# Overlay private configs if present. Each subdirectory in .private/ maps
# to a location in the user's home. Configs are copied (not symlinked) so
# tools have write access. Pre-built image layers (via private Dockerfile)
# are overwritten here to pick up any changes since last image build.
_overlay_private() {
    local src="$1" dest="$2"
    [ -d "$src" ] || return 0
    mkdir -p "$dest"
    cp -r "$src"/* "$dest/" 2>/dev/null || true
}

_overlay_private /devbox/.private/claude   "${DEVBOX_HOME}/.claude"
_overlay_private /devbox/.private/opencode "${DEVBOX_HOME}/.config/opencode"
_overlay_private /devbox/.private/nvim     "${DEVBOX_HOME}/.config/nvim"
_overlay_private /devbox/.private/tmux     "${DEVBOX_HOME}/.config/tmux"

# Tmux: if private config provides tmux.conf, symlink it to ~/.tmux.conf
# (tmux reads ~/.tmux.conf or ~/.config/tmux/tmux.conf depending on version).
if [ -f "${DEVBOX_HOME}/.config/tmux/tmux.conf" ]; then
    ln -sf "${DEVBOX_HOME}/.config/tmux/tmux.conf" "${DEVBOX_HOME}/.tmux.conf"
fi
# Tmux local overrides.
if [ -f "${DEVBOX_HOME}/.config/tmux/tmux.conf.local" ]; then
    ln -sf "${DEVBOX_HOME}/.config/tmux/tmux.conf.local" "${DEVBOX_HOME}/.tmux.conf.local"
fi

# Zsh: overlay .zshrc if provided (replaces the default devbox zshrc).
if [ -f /devbox/.private/.zshrc ]; then
    cp /devbox/.private/.zshrc "${DEVBOX_HOME}/.zshrc"
fi

# --- Working Directory ---
if [ ! -d /workspace ]; then
    echo "[entrypoint] FATAL: /workspace is not mounted or does not exist"
    exit 1
fi

# --- Ownership ---
# Ensure the devbox user owns its config and data directories.
# Covers: .config/ (nvim, opencode, tmux), .claude/, .oh-my-zsh/, and shell dotfiles.
chown -R devbox:devbox \
    "${DEVBOX_HOME}/.config" \
    "${DEVBOX_HOME}/.claude" \
    "${DEVBOX_HOME}/.oh-my-zsh" \
    2>/dev/null || true
chown devbox:devbox \
    "${DEVBOX_HOME}/.zshrc" \
    "${DEVBOX_HOME}/.tmux.conf" \
    "${DEVBOX_HOME}/.tmux.conf.local" \
    2>/dev/null || true
# Workspace needs write access for the non-root user.
chown devbox:devbox /workspace

# --- Launch as non-root ---
# Firewall is set up (requires root). Drop to unprivileged user.
# Default: hold container open as an isolated environment for exec sessions.
cd /workspace
if [ $# -eq 0 ]; then
    echo "[entrypoint] Environment ready. Accepting exec sessions."
    exec gosu devbox tail -f /dev/null
else
    exec gosu devbox "$@"
fi
