#!/usr/bin/env python3
"""
cmux filtering proxy: TCP relay to cmux Unix socket with command allowlist.

Listens on 127.0.0.1 (ephemeral port) and relays commands to the cmux
socket, blocking dangerous methods. Only safe sidebar/notification
commands are allowed through.

cmux uses two wire protocols:
  - Text protocol for sidebar commands: "set_status key value --tab=UUID"
  - JSON-RPC for notifications/system: {"method":"notification.create",...}

This proxy accepts both and filters by command/method name. It injects
the workspace ID (--tab= for text, workspace_id for JSON) so the
container doesn't need to know it.

Started automatically by devbox when cmux is detected. Exits after 60s
of idle (no active connections).
"""

import atexit
import json
import os
import signal
import socket
import sys
import threading
import time
from pathlib import Path
from typing import Optional

# -- Command filtering ---------------------------------------------------------

# Text-protocol commands that are safe (sidebar metadata only).
ALLOWED_TEXT_COMMANDS = frozenset({
    "set_status", "clear_status", "list_status",
    "set_progress", "clear_progress",
    "log", "clear_log", "list_log",
    "sidebar_state",
})

# JSON-RPC methods that are safe.
ALLOWED_JSON_METHODS = frozenset({
    "notification.create", "notification.list", "notification.clear",
    "system.ping", "system.capabilities", "system.identify",
})


def is_text_command_allowed(line: str) -> bool:
    """Check if a text-protocol command is in the allowlist."""
    command = line.split()[0] if line.strip() else ""
    return command in ALLOWED_TEXT_COMMANDS


def is_json_method_allowed(method: str) -> bool:
    """Check if a JSON-RPC method is in the allowlist."""
    return method in ALLOWED_JSON_METHODS


def is_method_allowed(method: str) -> bool:
    """Check if a method/command name is allowed (either protocol)."""
    if not method:
        return False
    return method in ALLOWED_TEXT_COMMANDS or method in ALLOWED_JSON_METHODS


def make_error_response(req_id: Optional[str], message: str) -> str:
    """Generate a JSON error response."""
    return json.dumps({"id": req_id, "ok": False, "error": message})


# -- Connection handling -------------------------------------------------------

class ProxyState:
    """Shared state for tracking connections and idle timeout."""

    def __init__(self, idle_timeout: int = 60) -> None:
        self.active_connections = 0
        self.last_activity = time.monotonic()
        self.idle_timeout = idle_timeout
        self.lock = threading.Lock()

    def connect(self) -> None:
        with self.lock:
            self.active_connections += 1
            self.last_activity = time.monotonic()

    def disconnect(self) -> None:
        with self.lock:
            self.active_connections -= 1
            self.last_activity = time.monotonic()

    def is_idle(self) -> bool:
        with self.lock:
            if self.active_connections > 0:
                return False
            return (time.monotonic() - self.last_activity) > self.idle_timeout


def _is_json(line: str) -> bool:
    """Check if a line looks like JSON (starts with '{')."""
    return line.lstrip().startswith("{")


def _inject_workspace_text(line: str, workspace_id: str) -> str:
    """Inject --tab=workspace into a text-protocol command if not present."""
    if "--tab=" in line:
        return line
    return f"{line} --tab={workspace_id}"


def _inject_workspace_json(msg: dict, workspace_id: str) -> dict:  # type: ignore[type-arg]
    """Inject workspace_id into JSON-RPC params if not present."""
    params = msg.get("params") or {}
    if "workspace_id" not in params:
        params["workspace_id"] = workspace_id
        msg["params"] = params
    return msg


def handle_client(
    client: socket.socket,
    cmux_socket_path: str,
    workspace_id: str,
    state: ProxyState,
) -> None:
    """Handle a single TCP client connection."""
    state.connect()
    cmux: Optional[socket.socket] = None
    try:
        cmux = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        cmux.connect(cmux_socket_path)
        cmux.settimeout(5.0)

        buf = b""
        client.settimeout(30.0)
        while True:
            data = client.recv(4096)
            if not data:
                break
            buf += data
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line_str = line.decode("utf-8", errors="replace").strip()
                if not line_str:
                    continue

                if _is_json(line_str):
                    # JSON-RPC protocol (notifications, system commands).
                    try:
                        msg = json.loads(line_str)
                        method = msg.get("method", "")
                        req_id = msg.get("id")
                    except (json.JSONDecodeError, AttributeError):
                        resp = make_error_response(None, "invalid JSON")
                        client.sendall((resp + "\n").encode())
                        continue

                    if is_json_method_allowed(method):
                        if workspace_id:
                            msg = _inject_workspace_json(msg, workspace_id)
                        forwarded = json.dumps(msg).encode() + b"\n"
                        cmux.sendall(forwarded)
                        cmux_resp = b""
                        while b"\n" not in cmux_resp:
                            chunk = cmux.recv(4096)
                            if not chunk:
                                break
                            cmux_resp += chunk
                        client.sendall(cmux_resp)
                    else:
                        print(f"[cmux-proxy] blocked JSON: {method}", file=sys.stderr)
                        resp = make_error_response(
                            req_id, f"method '{method}' blocked by devbox proxy"
                        )
                        client.sendall((resp + "\n").encode())
                else:
                    # Text protocol (sidebar commands).
                    if is_text_command_allowed(line_str):
                        if workspace_id:
                            line_str = _inject_workspace_text(line_str, workspace_id)
                        cmux.sendall((line_str + "\n").encode())
                        cmux_resp = b""
                        while b"\n" not in cmux_resp:
                            chunk = cmux.recv(4096)
                            if not chunk:
                                break
                            cmux_resp += chunk
                        client.sendall(cmux_resp)
                    else:
                        command = line_str.split()[0] if line_str else "(empty)"
                        print(f"[cmux-proxy] blocked text: {command}", file=sys.stderr)
                        client.sendall(b"ERR: command blocked by devbox proxy\n")

                state.last_activity = time.monotonic()
    except (OSError, ConnectionError):
        pass
    finally:
        client.close()
        if cmux is not None:
            try:
                cmux.close()
            except Exception:
                pass
        state.disconnect()


# -- Lifecycle management ------------------------------------------------------

DATA_DIR = Path.home() / ".devbox"
PID_FILE = DATA_DIR / "cmux-proxy.pid"
PORT_FILE = DATA_DIR / "cmux-proxy.port"


def cleanup() -> None:
    """Remove PID and port files on exit."""
    PID_FILE.unlink(missing_ok=True)
    PORT_FILE.unlink(missing_ok=True)


def main() -> None:
    cmux_socket_path = os.environ.get("CMUX_SOCKET_PATH", "")
    if not cmux_socket_path:
        print("[cmux-proxy] CMUX_SOCKET_PATH not set, exiting", file=sys.stderr)
        sys.exit(1)

    if not Path(cmux_socket_path).exists():
        print(
            f"[cmux-proxy] socket not found: {cmux_socket_path}", file=sys.stderr
        )
        sys.exit(1)

    workspace_id = os.environ.get("CMUX_WORKSPACE_ID", "")
    idle_timeout = int(os.environ.get("DEVBOX_CMUX_PROXY_IDLE", "60"))
    state = ProxyState(idle_timeout=idle_timeout)

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(8)
    server.settimeout(1.0)

    port = server.getsockname()[1]

    # Write PID and port files.
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    PID_FILE.write_text(str(os.getpid()))
    PORT_FILE.write_text(str(port))
    atexit.register(cleanup)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))

    print(f"[cmux-proxy] listening on 127.0.0.1:{port}", file=sys.stderr)
    print(f"[cmux-proxy] relaying to {cmux_socket_path}", file=sys.stderr)
    if workspace_id:
        print(f"[cmux-proxy] workspace: {workspace_id}", file=sys.stderr)

    while True:
        try:
            client, _ = server.accept()
            t = threading.Thread(
                target=handle_client,
                args=(client, cmux_socket_path, workspace_id, state),
                daemon=True,
            )
            t.start()
        except socket.timeout:
            if state.is_idle():
                print("[cmux-proxy] idle timeout, exiting", file=sys.stderr)
                break
        except OSError:
            break

    server.close()


if __name__ == "__main__":
    main()
