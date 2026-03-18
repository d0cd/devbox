"""
mitmproxy addon: domain allowlist enforcer.

Reads a YAML policy file and blocks HTTP/HTTPS requests to domains not
in the allowlist. Only exact matches and *. prefix wildcards are supported
to prevent accidental over-matching.

Derived from mattolson/agent-sandbox (MIT).
"""

import logging
import os
import time
from pathlib import Path

import yaml
from mitmproxy import ctx, http

POLICY_PATH = Path("/proxy/policy.yml")
BLOCKED_BODY_PREFIX = "BLOCKED by devbox enforcer: "
BLOCKED_BODY_SUFFIX = " is not in the allowlist"
try:
    RELOAD_INTERVAL = int(os.environ.get("DEVBOX_RELOAD_INTERVAL", "30"))
except ValueError:
    RELOAD_INTERVAL = 30

# Module-level logger for standalone functions (usable outside mitmproxy).
# Addon methods use ctx.log (mitmproxy's context logger) instead.
logger = logging.getLogger("enforcer")


def _load_allowlist(path: Path) -> list[str]:
    """Load allowed domains from a YAML policy file.

    Returns an empty list on any error (fail-closed — blocks all traffic).
    """
    MAX_POLICY_SIZE = 1_048_576  # 1 MB
    try:
        file_size = path.stat().st_size
        if file_size > MAX_POLICY_SIZE:
            logger.error("Policy file too large (%d bytes)", file_size)
            return []
        with open(path, "r") as f:
            data = yaml.safe_load(f)
    except FileNotFoundError:
        logger.warning("Policy file not found at %s — blocking all traffic", path)
        return []
    except (OSError, yaml.YAMLError) as e:
        logger.error("Failed to read policy file %s: %s", path, e)
        return []

    if not isinstance(data, dict) or "allowed" not in data:
        logger.error("Invalid policy file: missing 'allowed' key")
        return []

    allowed = data["allowed"]
    if not isinstance(allowed, list):
        logger.error("Invalid policy file: 'allowed' must be a list")
        return []

    entries = []
    for domain in allowed:
        d = str(domain).lower().strip()
        # Only allow exact domains and *. prefix wildcards.
        if not d:
            continue
        if d.count("*") > 1 or ("*" in d and not d.startswith("*.")):
            logger.warning("Ignoring unsupported wildcard pattern: %s", d)
            continue
        entries.append(d)

    return entries


def _is_allowed(host: str, allowlist: list[str]) -> bool:
    """Check if a host matches any entry in the allowlist.

    Supports exact matches and *. prefix wildcards (e.g. *.example.com
    matches sub.example.com and example.com itself).
    """
    host = host.lower()
    for pattern in allowlist:
        if pattern.startswith("*."):
            # Wildcard: match the base domain and any subdomain.
            base = pattern[2:]
            if host == base or host.endswith("." + base):
                return True
        elif host == pattern:
            return True
    return False


class Enforcer:
    """mitmproxy addon that enforces a domain allowlist."""

    def __init__(self) -> None:
        self.allowlist: list[str] = []
        self._policy_mtime: float = 0.0
        self._last_check: float = 0.0

    def load(self, loader: object) -> None:
        """Called when the addon is loaded. Reads the policy file."""
        self._reload_policy()

    def _reload_policy(self) -> None:
        """Load (or reload) the policy file and update mtime tracking."""
        old_allowlist = self.allowlist
        self.allowlist = _load_allowlist(POLICY_PATH)
        try:
            if POLICY_PATH.exists():
                self._policy_mtime = POLICY_PATH.stat().st_mtime
        except OSError as e:
            ctx.log.warn(f"Failed to stat policy file: {e}")
        self._last_check = time.monotonic()
        if self.allowlist != old_allowlist:
            ctx.log.info(
                f"Enforcer loaded with {len(self.allowlist)} allowed domains"
                f" from {POLICY_PATH}"
            )

    def _maybe_reload(self) -> None:
        """Check if the policy file has changed and reload if needed."""
        now = time.monotonic()
        if now - self._last_check < RELOAD_INTERVAL:
            return
        self._last_check = now
        try:
            if POLICY_PATH.exists():
                mtime = POLICY_PATH.stat().st_mtime
                if mtime != self._policy_mtime:
                    ctx.log.info("Policy file changed, reloading...")
                    self._reload_policy()
        except OSError as e:
            ctx.log.warn(f"Failed to check policy file: {e}")

    def _blocked_body(self, host: str) -> bytes:
        """Generate a per-request blocked response body."""
        # Truncate host to prevent oversized responses from malicious Host headers.
        safe_host = host[:253] if len(host) > 253 else host
        return f"{BLOCKED_BODY_PREFIX}{safe_host}{BLOCKED_BODY_SUFFIX}".encode()

    def request(self, flow: http.HTTPFlow) -> None:
        """Block HTTP requests to non-allowed domains."""
        self._maybe_reload()
        host = flow.request.pretty_host
        if not _is_allowed(host, self.allowlist):
            ctx.log.warn(f"BLOCKED request to {host}")
            flow.response = http.Response.make(
                403,
                self._blocked_body(host),
                {"Content-Type": "text/plain"},
            )

    def http_connect(self, flow: http.HTTPFlow) -> None:
        """Block HTTPS CONNECT tunnels to non-allowed domains."""
        self._maybe_reload()
        host = flow.request.pretty_host
        if not _is_allowed(host, self.allowlist):
            ctx.log.warn(f"BLOCKED CONNECT tunnel to {host}")
            flow.response = http.Response.make(
                403,
                self._blocked_body(host),
                {"Content-Type": "text/plain"},
            )


addons = [Enforcer()]
