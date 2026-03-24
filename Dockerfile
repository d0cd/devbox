# Agent container: Ubuntu 24.04 with all AI CLI tools and dev environment.
# Two-stage build: builder installs toolchains, runtime copies only artifacts.

# --- Stage 1: Builder ---
FROM ubuntu:24.04@sha256:186072bba1b2f436cbb91ef2567abca677337cfc786c86e107d25b7072feef0c AS builder

# Prevent interactive prompts during package installation.
ENV DEBIAN_FRONTEND=noninteractive

# System packages needed for build-time fetches.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    python3 \
    unzip \
    wget \
    zsh

# Node.js 22 LTS (required by gemini-cli, codex — need >= 20).
# hadolint ignore=DL3008
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs

# uv (Python tooling) — COPY layers are very cacheable.
COPY --from=ghcr.io/astral-sh/uv:0.10.10 /uv /usr/local/bin/uv

# AI CLI tools via npm (pinned versions — cache-friendly, install before git clones).
ARG OPENCODE_VERSION=1.2.26
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    npm install -g --omit=dev opencode-ai@${OPENCODE_VERSION} \
    @google/gemini-cli@0.33.1 @openai/codex@0.114.0 @anthropic-ai/claude-code@2.1.76 \
    gsd-opencode@1.22.1

# GitHub CLI.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | tee /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh

# Oh My Zsh + common plugins (external git repos — least cacheable, last).
# p10k is deliberately excluded — the default devbox prompt is minimal.
# Users who want p10k can install it via their private overlay Dockerfile.
RUN git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git /root/.oh-my-zsh \
    && git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git \
        /root/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting \
    && git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions.git \
        /root/.oh-my-zsh/custom/plugins/zsh-autosuggestions

# --- Stage 2: Runtime ---
FROM ubuntu:24.04@sha256:186072bba1b2f436cbb91ef2567abca677337cfc786c86e107d25b7072feef0c

ARG DEVBOX_VERSION=0.3.0
LABEL org.opencontainers.image.title="devbox-agent" \
      org.opencontainers.image.version="${DEVBOX_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive

# Install curl + ca-certificates first (needed for NodeSource setup).
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl

# Node.js 22 LTS (runtime needs node for npm global binaries).
# hadolint ignore=DL3008
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs

# Runtime-only system packages.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    bash \
    delta \
    fzf \
    git \
    gosu \
    iproute2 \
    iptables \
    jq \
    neovim \
    python3 \
    sqlite3 \
    tmux \
    zsh

# Create non-root user for running the agent after firewall setup.
# Fixed UID/GID 1000 — must match the tmpfs uid/gid in docker-compose.yml.
# Ubuntu 24.04 ships with a 'ubuntu' user/group at 1000; remove it first.
RUN (getent group 1000 | cut -d: -f1 | xargs -r groupdel) 2>/dev/null; \
    (getent passwd 1000 | cut -d: -f1 | xargs -r userdel) 2>/dev/null; \
    groupadd -g 1000 devbox && useradd -u 1000 -g devbox -m -d /home/devbox -s /bin/zsh devbox \
    && usermod -aG tty devbox

# --- Copy artifacts from builder ---

# Oh My Zsh framework — installed to /opt (read-only rootfs safe).
# The ZSH env var in .zshrc points here instead of ~/.oh-my-zsh.
COPY --from=builder /root/.oh-my-zsh /opt/oh-my-zsh
RUN chown -R devbox:devbox /opt/oh-my-zsh

# npm global packages (includes OpenCode, Gemini CLI, Codex, Claude Code, etc.).
COPY --from=builder /usr/lib/node_modules /usr/lib/node_modules
COPY --from=builder /usr/bin/opencode /usr/bin/gemini /usr/bin/codex /usr/bin/claude /usr/bin/gsd-opencode /usr/bin/

# GitHub CLI keyring + binary.
COPY --from=builder /usr/share/keyrings/githubcli-archive-keyring.gpg /usr/share/keyrings/githubcli-archive-keyring.gpg
COPY --from=builder /usr/bin/gh /usr/bin/gh

# uv binary.
COPY --from=builder /usr/local/bin/uv /usr/local/bin/uv

# --- Shell configuration ---
# Default configs go to /etc/skel so user-setup.sh can populate the tmpfs home.
COPY templates/zshrc /etc/skel/.zshrc
COPY templates/tmux.conf /etc/skel/.tmux.conf

# --- Library scripts and profiles ---
COPY lib/firewall.sh /usr/local/lib/devbox/firewall.sh
COPY tooling/profiles/ /usr/local/lib/devbox/profiles/

# --- Entrypoint ---
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY user-setup.sh /usr/local/bin/user-setup.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/user-setup.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# Default: hold container open as isolated dev environment.
# Users exec into it: docker compose exec agent gosu devbox claude
