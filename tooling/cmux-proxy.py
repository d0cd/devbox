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

Started automatically by devbox when cmux is detected. Exits after
idle timeout (default: 3600s / 1 hour, configurable via DEVBOX_CMUX_PROXY_IDLE).
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
ALLOWED_TEXT_COMMANDS = frozenset(
    {
        "set_status",
        "clear_status",
        "list_status",
        "set_progress",
        "clear_progress",
        "log",
        "clear_log",
        "list_log",
        "sidebar_state",
        "notify",
        "notify_target",
    }
)

# JSON-RPC methods that are safe.
ALLOWED_JSON_METHODS = frozenset(
    {
        "notification.create",
        "notification.create_for_surface",
        "notification.create_for_target",
        "notification.list",
        "notification.clear",
        "system.ping",
        "system.capabilities",
        "system.identify",
    }
)


def is_text_command_allowed(line: str) -> bool:
    """Check if a text-protocol command is in the allowlist."""
    command = line.split()[0] if line.strip() else ""
    return command in ALLOWED_TEXT_COMMANDS


def is_json_method_allowed(method: str) -> bool:
    """Check if a JSON-RPC method is in the allowlist."""
    if method in ALLOWED_JSON_METHODS:
        return True
    # Allow claude-hook.* methods (forwarded from container hooks).
    if method.startswith("claude-hook."):
        return True
    return False


def is_method_allowed(method: str) -> bool:
    """Check if a method/command name is allowed (either protocol)."""
    if not method:
        return False
    return is_text_command_allowed(method) or is_json_method_allowed(method)


CMUX_CLI = "/Applications/cmux.app/Contents/Resources/bin/cmux"

ALLOWED_CLAUDE_HOOK_EVENTS = frozenset(
    {
        "session-start",
        "active",
        "stop",
        "idle",
        "notification",
        "notify",
        "prompt-submit",
        "pre-tool-use",
        "session-end",
    }
)


def _handle_claude_hook(method: str, msg: dict, client: socket.socket) -> None:
    """Forward claude-hook.* methods to the cmux CLI on the host.

    The cmux CLI reads hook JSON from stdin and handles all the rich
    status/notification/sidebar logic internally.
    """
    import subprocess

    event = method.removeprefix("claude-hook.")
    if event not in ALLOWED_CLAUDE_HOOK_EVENTS:
        resp = json.dumps(
            {"id": msg.get("id"), "ok": False, "error": f"unknown event: {event}"}
        )
        client.sendall((resp + "\n").encode())
        return
    data = msg.get("params", {})
    try:
        result = subprocess.run(
            [CMUX_CLI, "claude-hook", event],
            input=json.dumps(data),
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode != 0:
            print(
                f"[cmux-proxy] claude-hook {event} failed (rc={result.returncode}): {result.stderr.strip()}",
                file=sys.stderr,
            )
        resp = json.dumps({"id": msg.get("id"), "ok": result.returncode == 0})
        client.sendall((resp + "\n").encode())
    except Exception as e:
        print(f"[cmux-proxy] claude-hook failed: {e}", file=sys.stderr)
        resp = json.dumps({"id": msg.get("id"), "ok": False, "error": str(e)})
        client.sendall((resp + "\n").encode())


def _devbox_sessions_running() -> bool:
    """Check if any devbox containers are running."""
    import subprocess

    try:
        result = subprocess.run(
            ["docker", "compose", "ls", "--format", "json"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            return False
        # Check for any project starting with "devbox-".
        return "devbox-" in result.stdout
    except Exception:
        return False


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


class CmuxConnection:
    """Thread-safe cmux socket connection with automatic reconnect."""

    def __init__(self, socket_path: str) -> None:
        self._path = socket_path
        self._sock: Optional[socket.socket] = None
        self._lock = threading.Lock()

    def connect(self) -> None:
        """Open the cmux socket connection."""
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.connect(self._path)
        self._sock.settimeout(5.0)

    def send_recv(self, payload: bytes) -> bytes:
        """Send payload and read response. Reconnects once on failure."""
        with self._lock:
            for attempt in range(2):
                try:
                    if self._sock is None:
                        self.connect()
                    self._sock.sendall(payload)
                    resp = b""
                    while b"\n" not in resp:
                        chunk = self._sock.recv(4096)
                        if not chunk:
                            raise ConnectionError("cmux socket closed")
                        resp += chunk
                    return resp
                except (OSError, ConnectionError) as e:
                    if attempt == 0:
                        print(f"[cmux-proxy] cmux connection lost, reconnecting: {e}", file=sys.stderr)
                        try:
                            if self._sock:
                                self._sock.close()
                        except Exception:
                            pass
                        self._sock = None
                    else:
                        raise
            return b""


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
    cmux: CmuxConnection = None,
) -> None:
    """Handle a single TCP client connection."""
    state.connect()
    try:
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
                        if method.startswith("claude-hook."):
                            # Forward to cmux CLI on the host.
                            _handle_claude_hook(method, msg, client)
                        else:
                            if workspace_id:
                                msg = _inject_workspace_json(msg, workspace_id)
                            forwarded = json.dumps(msg).encode() + b"\n"
                            try:
                                cmux_resp = cmux.send_recv(forwarded)
                                client.sendall(cmux_resp)
                            except (OSError, ConnectionError):
                                client.sendall(make_error_response(req_id, "cmux unavailable").encode() + b"\n")
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
                        try:
                            cmux_resp = cmux.send_recv((line_str + "\n").encode())
                            client.sendall(cmux_resp)
                        except (OSError, ConnectionError):
                            client.sendall(b"ERR: cmux unavailable\n")
                    else:
                        command = line_str.split()[0] if line_str else "(empty)"
                        print(f"[cmux-proxy] blocked text: {command}", file=sys.stderr)
                        client.sendall(b"ERR: command blocked by devbox proxy\n")

                state.last_activity = time.monotonic()
    except (OSError, ConnectionError) as exc:
        print(f"[cmux-proxy] client disconnected: {exc}", file=sys.stderr)
    finally:
        client.close()
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
        print(f"[cmux-proxy] socket not found: {cmux_socket_path}", file=sys.stderr)
        sys.exit(1)

    workspace_id = os.environ.get("CMUX_WORKSPACE_ID", "")
    idle_timeout = int(os.environ.get("DEVBOX_CMUX_PROXY_IDLE", "3600"))
    state = ProxyState(idle_timeout=idle_timeout)

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    FIXED_PORT = 19876
    server.bind(("127.0.0.1", FIXED_PORT))
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

    # Open cmux connection NOW (while we're still in the cmux process tree).
    # CmuxConnection handles reconnection if the socket drops (sleep/wake).
    cmux_conn = CmuxConnection(cmux_socket_path)
    try:
        cmux_conn.connect()
    except OSError as e:
        print(f"[cmux-proxy] failed to connect to cmux socket: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"[cmux-proxy] listening on 127.0.0.1:{port}", file=sys.stderr)
    print(f"[cmux-proxy] relaying to {cmux_socket_path}", file=sys.stderr)
    if workspace_id:
        print(f"[cmux-proxy] workspace: {workspace_id}", file=sys.stderr)

    while True:
        try:
            client, _ = server.accept()
            t = threading.Thread(
                target=handle_client,
                args=(
                    client,
                    cmux_socket_path,
                    workspace_id,
                    state,
                    cmux_conn,
                ),
                daemon=True,
            )
            t.start()
        except socket.timeout:
            if state.is_idle() and not _devbox_sessions_running():
                print("[cmux-proxy] no active devbox sessions, exiting", file=sys.stderr)
                break
        except OSError:
            break

    server.close()


if __name__ == "__main__":
    main()
