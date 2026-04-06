"""
mitmproxy addon: cmux notification forwarder.

Intercepts requests to the special /_devbox/ path and forwards them to
the cmux proxy on the host via TCP. This keeps all agent traffic routed
through the proxy sidecar — no direct container-to-host connections.

The agent sends:  POST http://proxy:8080/_devbox/notify  {"title":"...","body":"..."}
The proxy sends:  JSON-RPC notification.create  →  host.docker.internal:$CMUX_PROXY_PORT
"""

from __future__ import annotations

import json
import os
import socket

from mitmproxy import ctx, http

DEVBOX_PATH_PREFIX = "/_devbox/"


class CmuxNotifier:
    def request(self, flow: http.HTTPFlow) -> None:
        """Intercept /_devbox/ requests and handle internally."""
        if not flow.request.path.startswith(DEVBOX_PATH_PREFIX):
            return

        # Don't forward to the internet — handle locally.
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
        """Forward a notification to the cmux proxy on the host as JSON-RPC."""
        try:
            body = json.loads(flow.request.get_content())
            title = body.get("title", "devbox")
            msg = body.get("body", "")
            rpc = {
                "id": "notify",
                "method": "notification.create",
                "params": {"title": title, "body": msg},
            }
            self._send_to_proxy(json.dumps(rpc) + "\n")
            flow.response = http.Response.make(200, b"OK")
        except Exception as e:
            ctx.log.warn(f"[notifier] Failed to forward notification: {e}")
            flow.response = http.Response.make(200, b"OK")  # Don't break the agent.

    def _handle_status(self, flow: http.HTTPFlow) -> None:
        """Forward a status command to the cmux proxy on the host."""
        try:
            payload = flow.request.get_content().decode() + "\n"
            self._send_to_proxy(payload)
            flow.response = http.Response.make(200, b"OK")
        except Exception as e:
            ctx.log.warn(f"[notifier] Failed to forward status: {e}")
            flow.response = http.Response.make(200, b"OK")

    def _handle_claude_hook(self, flow: http.HTTPFlow) -> None:
        """Forward Claude Code hook data to cmux claude-hook on the host.

        The container sends: {"event": "stop", "data": {...hook JSON...}}
        The proxy forwards the data JSON to the cmux proxy as:
            claude-hook <event> <json>\n
        The cmux proxy relays to cmux claude-hook.
        """
        try:
            body = json.loads(flow.request.get_content())
            event = body.get("event", "")
            data = body.get("data", {})
            if not event:
                flow.response = http.Response.make(400, b"Missing event")
                return
            # Send as a JSON-RPC call to the cmux proxy.
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
            # Read the response before closing to avoid broken pipe on the proxy.
            sock.settimeout(2)
            try:
                sock.recv(4096)
            except (socket.timeout, OSError):
                pass
            sock.close()
        except Exception as e:
            ctx.log.info(f"[notifier] cmux proxy unavailable: {e}")


addons = [CmuxNotifier()]
