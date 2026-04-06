#!/usr/bin/env bash
# Phase 2 of agent container startup — runs as the unprivileged devbox user.
#
# Configures git identity, overlays private configs, and holds the container
# open for exec sessions. Called by entrypoint.sh via gosu.
set -euo pipefail

DEVBOX_HOME="/home/devbox"

# --- Populate home directory ---
# With read_only rootfs, /home/devbox is a tmpfs mount (empty at start).
# Copy default configs from /etc/skel (baked into the image).
if [ ! -f "${DEVBOX_HOME}/.zshrc" ]; then
    cp -a /etc/skel/. "${DEVBOX_HOME}/" 2>/dev/null || true
fi
# Create essential directories.
mkdir -p "${DEVBOX_HOME}/.config" "${DEVBOX_HOME}/.cache" "${DEVBOX_HOME}/.local/share"

# --- Git Identity and Credentials ---
if [ -n "${GIT_AUTHOR_NAME:-}" ]; then
    git config --global user.name "$GIT_AUTHOR_NAME"
fi
if [ -n "${GIT_AUTHOR_EMAIL:-}" ]; then
    git config --global user.email "$GIT_AUTHOR_EMAIL"
fi
# Configure gh as git credential helper for HTTPS operations.
# GH_TOKEN (injected via secrets) is used automatically by gh and git.
if command -v gh &>/dev/null && [ -n "${GH_TOKEN:-}" ]; then
    gh auth setup-git 2>/dev/null || true
fi

# --- OpenCode Configuration ---
mkdir -p "${DEVBOX_HOME}/.config/opencode"
if [ -f /devbox/opencode/opencode.json ]; then
    ln -sf /devbox/opencode/opencode.json "${DEVBOX_HOME}/.config/opencode/opencode.json"
fi
if [ -d /devbox/opencode/pal ]; then
    ln -sf /devbox/opencode/pal "${DEVBOX_HOME}/.config/opencode/pal"
fi
for dir in skills agents commands; do
    if [ -d "/devbox/opencode/${dir}" ]; then
        cp -r "/devbox/opencode/${dir}" "${DEVBOX_HOME}/.config/opencode/${dir}"
    fi
done

# --- Private config overlay ---
_overlay_private() {
    local src="$1" dest="$2"
    [ -d "$src" ] || return 0
    mkdir -p "$dest" || { echo "[setup] WARNING: Cannot create $dest"; return 0; }
    if ! cp -r "$src"/* "$dest/" 2>/dev/null; then
        echo "[setup] WARNING: Failed to overlay $src → $dest (empty or permission denied)"
    fi
}

# ~/.claude/ is devbox-global persistent storage (separate from host's ~/.claude/).
# Overlay private configs (settings, hooks, skills) on top each start.
_overlay_private /devbox/.private/claude "${DEVBOX_HOME}/.claude"
_overlay_private /devbox/.private/opencode "${DEVBOX_HOME}/.config/opencode"
_overlay_private /devbox/.private/nvim "${DEVBOX_HOME}/.config/nvim"
_overlay_private /devbox/.private/tmux "${DEVBOX_HOME}/.config/tmux"

# Tmux symlinks for version compatibility.
if [ -f "${DEVBOX_HOME}/.config/tmux/tmux.conf" ]; then
    ln -sf "${DEVBOX_HOME}/.config/tmux/tmux.conf" "${DEVBOX_HOME}/.tmux.conf"
fi
if [ -f "${DEVBOX_HOME}/.config/tmux/tmux.conf.local" ]; then
    ln -sf "${DEVBOX_HOME}/.config/tmux/tmux.conf.local" "${DEVBOX_HOME}/.tmux.conf.local"
fi

# Zsh: overlay .zshrc and .p10k.zsh if provided.
if [ -f /devbox/.private/.zshrc ]; then
    cp /devbox/.private/.zshrc "${DEVBOX_HOME}/.zshrc"
fi
if [ -f /devbox/.private/.p10k.zsh ]; then
    cp /devbox/.private/.p10k.zsh "${DEVBOX_HOME}/.p10k.zsh"
fi

# --- Working Directory ---
if [ ! -d /workspace ]; then
    echo "[entrypoint] FATAL: /workspace is not mounted or does not exist"
    exit 1
fi

# --- Hold container open or run custom command ---
cd /workspace
if [ $# -eq 0 ]; then
    echo "[entrypoint] Environment ready. Accepting exec sessions."
    # Run tail in the background and wait — keeps bash as PID 1 so it
    # receives SIGTERM on container stop and shuts down cleanly.
    tail -f /dev/null &
    wait $!
else
    exec "$@"
fi
