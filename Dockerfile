# Agent container: Ubuntu 24.04 with all AI CLI tools and dev environment.
# Two-stage build: builder installs toolchains, runtime copies only artifacts.

# --- Stage 1: Builder ---
FROM ubuntu:24.04@sha256:d1e2e92c075e5ca139d51a140fff46f84315c0fdce203eab2807c7e495eff4f9 AS builder

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
    gsd-opencode@1.22.1 opencode-mem@2.11.12

# GitHub CLI.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | tee /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh

# Oh My Zsh + Powerlevel10k + common plugins (external git repos — least cacheable, last).
RUN git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git /root/.oh-my-zsh \
    && git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
        /root/.oh-my-zsh/custom/themes/powerlevel10k \
    && git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git \
        /root/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting \
    && git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions.git \
        /root/.oh-my-zsh/custom/plugins/zsh-autosuggestions

# --- Stage 2: Runtime ---
FROM ubuntu:24.04@sha256:d1e2e92c075e5ca139d51a140fff46f84315c0fdce203eab2807c7e495eff4f9

ARG DEVBOX_VERSION=0.3.0
LABEL org.opencontainers.image.title="devbox-agent" \
      org.opencontainers.image.version="${DEVBOX_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive

# Node.js 22 LTS (runtime needs node for npm global binaries).
# hadolint ignore=DL3008
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs

# Runtime-only system packages (curl kept for healthcheck).
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
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
RUN groupadd -r devbox && useradd -r -g devbox -m -d /home/devbox -s /bin/zsh devbox

# --- Copy artifacts from builder ---

# Oh My Zsh framework.
COPY --from=builder /root/.oh-my-zsh /home/devbox/.oh-my-zsh
RUN chown -R devbox:devbox /home/devbox/.oh-my-zsh

# npm global packages (includes OpenCode, Gemini CLI, Codex, Claude Code, etc.).
COPY --from=builder /usr/lib/node_modules /usr/lib/node_modules
COPY --from=builder /usr/bin/opencode /usr/bin/gemini /usr/bin/codex /usr/bin/claude /usr/bin/gsd /usr/bin/opencode-mem /usr/bin/

# GitHub CLI keyring + binary.
COPY --from=builder /usr/share/keyrings/githubcli-archive-keyring.gpg /usr/share/keyrings/githubcli-archive-keyring.gpg
COPY --from=builder /usr/bin/gh /usr/bin/gh

# uv binary.
COPY --from=builder /usr/local/bin/uv /usr/local/bin/uv

# --- Shell configuration ---
COPY templates/zshrc /home/devbox/.zshrc
COPY templates/tmux.conf /home/devbox/.tmux.conf
RUN chown devbox:devbox /home/devbox/.zshrc /home/devbox/.tmux.conf

# --- Library scripts and profiles ---
COPY lib/firewall.sh /usr/local/lib/devbox/firewall.sh
COPY tooling/profiles/ /usr/local/lib/devbox/profiles/

# --- Entrypoint ---
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# Default: hold container open as isolated dev environment.
# Users exec into it: docker compose exec agent gosu devbox claude
