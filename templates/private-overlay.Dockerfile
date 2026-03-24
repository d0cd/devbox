# Private config overlay — add this to your private configs repo as "Dockerfile".
#
# Use this for heavy installs (zsh themes, plugins) that should be cached in the
# Docker image layer. Config files (nvim, tmux, claude, zshrc) are overlaid at
# startup from the read-only mount — they don't need to be baked in here.
# Rebuild to update cached installs: devbox rebuild
#
# Build context: The build context is set to the PARENT of your configs repo
# (e.g., ~/.config/devbox/), so COPY paths reference your repo subdirectories
# directly (e.g., nvim/, tmux/, devbox/claude/).
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
#   export DEVBOX_PRIVATE_CONFIGS=~/my-configs  # or a git URL
#   devbox rebuild    # builds base + this overlay (cached)
#   devbox            # starts container with your configs

# hadolint ignore=DL3007
FROM devbox-agent:latest

# Example: install powerlevel10k and zsh-syntax-highlighting.
# Uncomment and customize as needed.
# RUN [ -d /home/devbox/.oh-my-zsh/custom/themes/powerlevel10k ] || \
#         git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
#             /home/devbox/.oh-my-zsh/custom/themes/powerlevel10k && \
#     [ -d /home/devbox/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting ] || \
#         git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git \
#             /home/devbox/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting && \
#     chown -R devbox:devbox /home/devbox/.oh-my-zsh/custom
