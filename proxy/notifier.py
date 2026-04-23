"""
mitmproxy addon: cmux notification forwarder.

Intercepts requests to the special /_devbox/ path and forwards them to
the cmux proxy on the host via TCP. All forwarded messages are tagged
with the session's CMUX_WORKSPACE_ID (baked in at container start) so
cmux commands land in the workspace that started the devbox session.

Any workspace/--tab override the agent tries to send is stripped — the
sidecar is the authoritative source for workspace binding.

The agent sends:  POST http://proxy:8080/_devbox/notify  {"title":"...","body":"..."}
The proxy sends:  JSON-RPC notification.create  →  host.docker.internal:$CMUX_PROXY_PORT
"""

from __future__ import annotations

import json
import os
import re
import socket

from mitmproxy import ctx, http

DEVBOX_PATH_PREFIX = "/_devbox/"

# Match --tab=VALUE and --workspace=VALUE in text-protocol commands, so we
# can strip anything the agent supplies before injecting our own.
_TAB_FLAG_RE = re.compile(r"\s+--(?:tab|workspace)=\S+")


def _workspace_id() -> str:
    """Return the CMUX_WORKSPACE_ID the sidecar was started with, or ''."""
    return os.environ.get("CMUX_WORKSPACE_ID", "").strip()


def _strip_user_tab(line: str) -> str:
    """Remove any agent-supplied --tab= or --workspace= flags."""
    return _TAB_FLAG_RE.sub("", line).strip()


class CmuxNotifier:
    def request(self, flow: http.HTTPFlow) -> None:
        """Intercept /_devbox/ requests and handle internally."""
        if not flow.request.path.startswith(DEVBOX_PATH_PREFIX):
            return

        path = flow.request.path[len(DEVBOX_PATH_PREFIX) :]

        if path == "notify" and flow.request.method == "POST":
            self._handle_notify(flow)
        elif path == "status" and flow.request.method == "POST":
            self._handle_status(flow)
        elif path == "claude-hook" and flow.request.method == "POST":
            self._handle_claude_hook(flow)
        else:
            flow.response = http.Response.make(
                404, b"Unknown devbox endpoint", {"Content-Type": "text/plain"}
            )

    def _handle_notify(self, flow: http.HTTPFlow) -> None:
        """Forward a notification to the cmux proxy, tagged with our workspace."""
        try:
            body = json.loads(flow.request.get_content())
            title = body.get("title", "devbox")
            msg = body.get("body", "")
            # Agent-supplied workspace_id is ignored — we always use the
            # sidecar's own, bound to the session that created this container.
            params = {"title": title, "body": msg}
            ws = _workspace_id()
            if ws:
                params["workspace_id"] = ws
            rpc = {
                "id": "notify",
                "method": "notification.create",
                "params": params,
            }
            self._send_to_proxy(json.dumps(rpc) + "\n")
            flow.response = http.Response.make(200, b"OK")
        except Exception as e:
            ctx.log.warn(f"[notifier] Failed to forward notification: {e}")
            flow.response = http.Response.make(200, b"OK")

    def _handle_status(self, flow: http.HTTPFlow) -> None:
        """Forward a text-protocol status command, rewriting the --tab flag."""
        try:
            payload = flow.request.get_content().decode().strip()
            # Strip anything the agent supplied, then inject our own tag.
            payload = _strip_user_tab(payload)
            ws = _workspace_id()
            if ws:
                payload = f"{payload} --tab={ws}"
            self._send_to_proxy(payload + "\n")
            flow.response = http.Response.make(200, b"OK")
        except Exception as e:
            ctx.log.warn(f"[notifier] Failed to forward status: {e}")
            flow.response = http.Response.make(200, b"OK")

    def _handle_claude_hook(self, flow: http.HTTPFlow) -> None:
        """Forward Claude Code hook data to cmux claude-hook on the host.

        The container sends: {"event": "stop", "data": {...hook JSON...}}
        We tag it with our workspace_id before forwarding.
        """
        try:
            body = json.loads(flow.request.get_content())
            event = body.get("event", "")
            data = body.get("data", {}) or {}
            if not event:
                flow.response = http.Response.make(400, b"Missing event")
                return
            # Inject sidecar's workspace_id (overrides any agent-supplied value).
            ws = _workspace_id()
            if ws and isinstance(data, dict):
                data = {**data, "workspace_id": ws}
            rpc = {
                "id": f"claude-hook-{event}",
                "method": f"claude-hook.{event}",
                "params": data,
            }
            self._send_to_proxy(json.dumps(rpc) + "\n")
            flow.response = http.Response.make(200, b"OK")
        except Exception as e:
            ctx.log.warn(f"[notifier] Failed to forward claude-hook: {e}")
            flow.response = http.Response.make(200, b"OK")

    def _send_to_proxy(self, payload: str) -> None:
        """Send a message to the cmux proxy on the host."""
        port = os.environ.get("DEVBOX_CMUX_PROXY_PORT", "19876")
        try:
            sock = socket.create_connection(
                ("host.docker.internal", int(port)), timeout=2
            )
            sock.sendall(payload.encode())
            sock.settimeout(2)
            try:
                sock.recv(4096)
            except (socket.timeout, OSError):
                pass
            sock.close()
        except Exception as e:
            ctx.log.info(f"[notifier] cmux proxy unavailable: {e}")


addons = [CmuxNotifier()]
