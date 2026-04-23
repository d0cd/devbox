"""
mitmproxy addon: domain allowlist enforcer.

Reads a YAML policy file and blocks HTTP/HTTPS requests to destinations
not in the allowlist. Entries match on host, and optionally on port:

  api.anthropic.com              # any port
  host.docker.internal:11434     # only port 11434 (e.g. ollama)
  *.example.com                  # wildcard, any port
  *.example.com:443              # wildcard, only port 443

Only exact matches and *. prefix wildcards are supported to prevent
accidental over-matching.

Derived from mattolson/agent-sandbox (MIT).
"""

from __future__ import annotations

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


def _split_entry(pattern: str) -> tuple[str, int | None]:
    """Split a policy entry into (host_pattern, port_or_none).

    Handles three syntaxes:
      hostname          — any port
      hostname:port     — specific port
      [ipv6]:port       — bracketed IPv6 with port (brackets stripped to
                          match mitmproxy's pretty_host, which is unbracketed)

    Unbracketed addresses containing multiple colons (bare IPv6 without
    a port) are returned unchanged.
    """
    # Bracketed IPv6: [::1] or [::1]:8080 — strip brackets so the host part
    # matches mitmproxy's pretty_host, which has no brackets.
    if pattern.startswith("["):
        end = pattern.find("]")
        if end != -1:
            host_part = pattern[1:end]  # strip brackets
            tail = pattern[end + 1 :]
            if tail.startswith(":"):
                port_str = tail[1:]
                if port_str.isdigit():
                    return host_part, int(port_str)
            return host_part, None
    # Only treat as host:port if there's exactly one colon (avoids
    # misinterpreting bare IPv6 as host:port).
    if pattern.count(":") == 1:
        host_part, port_str = pattern.split(":", 1)
        if port_str.isdigit():
            return host_part, int(port_str)
    return pattern, None


def _host_matches(host: str, host_pattern: str) -> bool:
    """Match host against an exact or *.-wildcard pattern."""
    if host_pattern.startswith("*."):
        base = host_pattern[2:]
        return host == base or host.endswith("." + base)
    return host == host_pattern


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
        if not d:
            continue
        # Reject entries that look like host:port but have a non-numeric port.
        # Bracketed IPv6 with port is handled below via _split_entry.
        if not d.startswith("[") and d.count(":") == 1:
            _, port_str = d.split(":", 1)
            if not port_str.isdigit():
                logger.warning("Ignoring entry with invalid port: %s", d)
                continue
        host_part, port = _split_entry(d)
        # Reject unsupported wildcard syntaxes (only *. prefix is allowed).
        if host_part.count("*") > 1 or ("*" in host_part and not host_part.startswith("*.")):
            logger.warning("Ignoring unsupported wildcard pattern: %s", d)
            continue
        # Reject out-of-range ports.
        if port is not None and not (0 < port < 65536):
            logger.warning("Ignoring entry with invalid port: %s", d)
            continue
        entries.append(d)

    return entries


def _is_allowed(host: str, allowlist: list[str], port: int | None = None) -> bool:
    """Check if a host[:port] matches any entry in the allowlist.

    Supports exact matches and *. prefix wildcards (e.g. *.example.com
    matches sub.example.com and example.com itself).

    Entries without a port match any port (backwards compatible).
    Entries with a port match only that port.
    """
    host = host.lower()
    for pattern in allowlist:
        host_pattern, entry_port = _split_entry(pattern)
        if not _host_matches(host, host_pattern):
            continue
        if entry_port is not None and port is not None and entry_port != port:
            continue
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
            ctx.log.warn(f"[enforcer] Failed to stat policy file: {e}")
        self._last_check = time.monotonic()
        if self.allowlist != old_allowlist:
            ctx.log.info(
                f"[enforcer] Loaded {len(self.allowlist)} allowed domains"
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
                    ctx.log.info("[enforcer] Policy file changed, reloading...")
                    self._reload_policy()
        except OSError as e:
            ctx.log.warn(f"[enforcer] Failed to check policy file: {e}")

    def _blocked_body(self, host: str) -> bytes:
        """Generate a per-request blocked response body."""
        # Truncate host to prevent oversized responses from malicious Host headers.
        safe_host = host[:253] if len(host) > 253 else host
        return f"{BLOCKED_BODY_PREFIX}{safe_host}{BLOCKED_BODY_SUFFIX}".encode()

    def request(self, flow: http.HTTPFlow) -> None:
        """Block HTTP requests to non-allowed host:port combinations."""
        # Skip /_devbox/ internal endpoints — handled by the notifier addon.
        if flow.request.path.startswith("/_devbox/"):
            return
        self._maybe_reload()
        host = flow.request.pretty_host
        port = flow.request.port
        if not _is_allowed(host, self.allowlist, port):
            ctx.log.warn(f"[enforcer] BLOCKED {flow.request.method} {host}:{port}")
            flow.response = http.Response.make(
                403,
                self._blocked_body(f"{host}:{port}"),
                {"Content-Type": "text/plain"},
            )

    def http_connect(self, flow: http.HTTPFlow) -> None:
        """Block HTTPS CONNECT tunnels to non-allowed host:port combinations."""
        self._maybe_reload()
        host = flow.request.pretty_host
        port = flow.request.port
        if not _is_allowed(host, self.allowlist, port):
            ctx.log.warn(f"[enforcer] BLOCKED CONNECT {host}:{port}")
            flow.response = http.Response.make(
                403,
                self._blocked_body(f"{host}:{port}"),
                {"Content-Type": "text/plain"},
            )


addons = [Enforcer()]
