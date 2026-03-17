#!/usr/bin/env bash
# devbox profile: Python
#
# VARIANTS: ml, api
# VARIANT_ml: PyTorch, NumPy, Pandas, Jupyter for machine learning
# VARIANT_api: FastAPI, uvicorn, httpx for API development
#
# Installs Python dev tooling via uv. Supports variants for specialized workflows.
# Idempotent — safe to run multiple times.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# Pinned tool versions (major.minor). Bump quarterly.
UV_VERSION="0.6"
RUFF_VERSION="0.9"
MYPY_VERSION="1.15"
PYTEST_VERSION="8"
IPYTHON_VERSION="8"

echo "[profile:python] Setting up Python environment..."

# Install uv if not present.
if ! command -v uv &>/dev/null; then
    echo "[profile:python] Installing uv..."
    curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | sh
    export PATH="$HOME/.local/bin:$PATH"
else
    echo "[profile:python] uv already installed."
fi

# Common dev tools.
echo "[profile:python] Installing dev tools..."
_warn_on_fail "ruff" uv tool install "ruff@${RUFF_VERSION}"
_warn_on_fail "mypy" uv tool install "mypy@${MYPY_VERSION}"
_warn_on_fail "pytest" uv tool install "pytest@${PYTEST_VERSION}"
_warn_on_fail "ipython" uv tool install "ipython@${IPYTHON_VERSION}"

# ML variant: install data science / ML packages.
if [ "${PROFILE_VARIANT:-}" = "ml" ]; then
    echo "[profile:python] Installing ML packages..."
    _warn_on_fail "jupyter" uv tool install jupyter
    if ! uv pip install --system numpy pandas torch; then
        echo "[profile:python] WARNING: ML package installation failed. Check disk space and network."
    fi
fi

# API variant: install web framework tools.
if [ "${PROFILE_VARIANT:-}" = "api" ]; then
    echo "[profile:python] Installing API development tools..."
    if ! uv pip install --system fastapi uvicorn httpx; then
        echo "[profile:python] WARNING: API package installation failed. Check disk space and network."
    fi
fi

echo "[profile:python] Python profile complete."
python3 --version
uv --version
