# Private config overlay — add this to your private configs repo as "Dockerfile".
#
# Layers your personal configs (nvim, tmux, zsh, claude) on top of the
# devbox base image and pre-installs nvim plugins so they're cached.
# The entrypoint re-copies configs from the read-only mount at startup,
# so edits to your configs repo take effect without rebuilding.
# Rebuild the image to re-cache nvim plugins: devbox rebuild
#
# Expected repo structure:
#   your-configs/
#   ├── Dockerfile          (this file)
#   ├── claude/             Claude Code config (settings.json, hooks, skills)
#   ├── nvim/               Neovim config (init.lua, lua/, lazy-lock.json)
#   ├── tmux/               Tmux config (tmux.conf, tmux.conf.local)
#   ├── opencode/           OpenCode config (opencode.json, agents, skills)
#   └── .zshrc              Zsh config (replaces default devbox zshrc)
#
# Usage:
#   export DEVBOX_PRIVATE_CONFIGS=git@github.com:you/configs.git
#   devbox rebuild    # builds base + this overlay (cached)
#   devbox            # starts container with your configs

FROM devbox-agent:latest

# Copy configs into the image layer (cached until files change).
# Comment out any COPY lines for directories you don't have.
COPY --chown=devbox:devbox claude/ /home/devbox/.claude/
COPY --chown=devbox:devbox nvim/   /home/devbox/.config/nvim/
COPY --chown=devbox:devbox tmux/   /home/devbox/.config/tmux/
COPY --chown=devbox:devbox .zshrc  /home/devbox/.zshrc

# Symlink tmux configs for version compatibility.
RUN ln -sf /home/devbox/.config/tmux/tmux.conf /home/devbox/.tmux.conf \
    && ln -sf /home/devbox/.config/tmux/tmux.conf.local /home/devbox/.tmux.conf.local 2>/dev/null || true

# Pre-install nvim plugins (Lazy) — cached until lazy-lock.json changes.
# This avoids downloading plugins on every container start.
RUN gosu devbox nvim --headless "+Lazy! sync" +qa 2>/dev/null || true
