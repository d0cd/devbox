"""
mitmproxy addon: proxy-layer credential injection.

Injects API credentials into outbound requests based on destination domain.
Real credentials live only in the proxy — the agent container receives
phantom tokens that satisfy tool startup checks but have no real value.

For each request to a known provider domain, the injector:
1. Strips any existing auth header (prevents agent from exfiltrating keys)
2. Injects the real credential from the proxy's environment

Loads between enforcer.py and logger.py in the addon chain. If no
DEVBOX_INJECT_* environment variables are set, acts as a no-op.
"""

import logging
import os
from typing import NamedTuple

from mitmproxy import ctx, http

# Module-level logger for standalone functions (usable outside mitmproxy).
logger = logging.getLogger("injector")


class ProviderSpec(NamedTuple):
    """Defines how to inject credentials for a specific API provider."""

    domain: str
    header: str  # header name (lowercase)
    format: str  # "raw" = value as-is, "bearer" = "Bearer {value}"
    env_var: str  # DEVBOX_INJECT_* environment variable name


# Hardcoded provider registry. The domain-to-header mapping is static —
# the agent cannot influence which domains receive credentials.
PROVIDERS: dict[str, ProviderSpec] = {
    "ANTHROPIC": ProviderSpec(
        domain="api.anthropic.com",
        header="x-api-key",
        format="raw",
        env_var="DEVBOX_INJECT_ANTHROPIC",
    ),
    "OPENAI": ProviderSpec(
        domain="api.openai.com",
        header="authorization",
        format="bearer",
        env_var="DEVBOX_INJECT_OPENAI",
    ),
    "GEMINI": ProviderSpec(
        domain="generativelanguage.googleapis.com",
        header="x-goog-api-key",
        format="raw",
        env_var="DEVBOX_INJECT_GEMINI",
    ),
    "OPENROUTER": ProviderSpec(
        domain="openrouter.ai",
        header="authorization",
        format="bearer",
        env_var="DEVBOX_INJECT_OPENROUTER",
    ),
    "GITHUB": ProviderSpec(
        domain="api.github.com",
        header="authorization",
        format="bearer",
        env_var="DEVBOX_INJECT_GITHUB",
    ),
}


def _load_credentials() -> dict[str, tuple[str, str]]:
    """Read DEVBOX_INJECT_* env vars and build a domain-to-credential map.

    Returns a dict mapping domain -> (header_name, formatted_value).
    Empty env vars and unknown provider names are silently skipped.
    """
    credentials: dict[str, tuple[str, str]] = {}
    for spec in PROVIDERS.values():
        value = os.environ.get(spec.env_var, "").strip()
        if not value:
            continue
        formatted = f"Bearer {value}" if spec.format == "bearer" else value
        credentials[spec.domain] = (spec.header, formatted)
    return credentials


class Injector:
    """mitmproxy addon that injects credentials into outbound requests."""

    def __init__(self) -> None:
        self._credentials: dict[str, tuple[str, str]] = {}

    def load(self, loader: object) -> None:
        """Called when the addon is loaded. Reads credentials from env."""
        self._credentials = _load_credentials()
        if self._credentials:
            ctx.log.info(
                f"[injector] Credential injection active for "
                f"{len(self._credentials)} provider(s): "
                + ", ".join(sorted(self._credentials.keys()))
            )
        else:
            ctx.log.info(
                "[injector] No DEVBOX_INJECT_* env vars set — "
                "credential injection disabled (pass-through mode)"
            )

    def request(self, flow: http.HTTPFlow) -> None:
        """Strip agent auth headers and inject real credentials."""
        # Skip flows already blocked by the enforcer.
        if flow.response is not None:
            return

        if not self._credentials:
            return

        host = flow.request.pretty_host.lower()
        cred = self._credentials.get(host)
        if cred is None:
            return

        header_name, header_value = cred

        # Strip any existing auth header the agent may have sent.
        if header_name in flow.request.headers:
            del flow.request.headers[header_name]

        # Inject the real credential.
        flow.request.headers[header_name] = header_value
        flow.metadata["devbox_injected"] = True


addons = [Injector()]
