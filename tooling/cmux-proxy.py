#!/usr/bin/env python3
"""
cmux filtering proxy: TCP relay to cmux Unix socket with command allowlist.

Listens on 127.0.0.1:19876 and relays commands to the cmux Unix socket,
blocking dangerous methods. Only safe sidebar/notification commands pass.

cmux uses two wire protocols:
  - Text protocol for sidebar commands: "set_status key value --tab=UUID"
  - JSON-RPC for notifications/system: {"method":"notification.create",...}

This proxy accepts both and filters by command/method name. It injects the
workspace ID (--tab= for text, workspace_id for JSON) so the container
doesn't need to know it.

Claude Code hook events (claude-hook.*) are handled inline using the cmux
socket protocol — no subprocess spawning required.

Managed by launchd (com.devbox.cmux-proxy). Restarts automatically on
crash or cmux socket reconnection failure.
"""

import json
import os
import re
import signal
import socket
import sys
import threading
import uuid
from pathlib import Path
from typing import Optional

# -- Configuration -------------------------------------------------------------

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 19876

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


def is_text_command_allowed(line: str) -> bool:
    command = line.split()[0] if line.strip() else ""
    return command in ALLOWED_TEXT_COMMANDS


def is_json_method_allowed(method: str) -> bool:
    if method in ALLOWED_JSON_METHODS:
        return True
    if method.startswith("claude-hook."):
        return True
    return False


# -- cmux socket connection ----------------------------------------------------


class CmuxConnection:
    """Thread-safe cmux socket connection with automatic reconnect."""

    def __init__(self, socket_path: str) -> None:
        self._path = socket_path
        self._sock: Optional[socket.socket] = None
        self._lock = threading.Lock()

    def connect(self) -> None:
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.connect(self._path)
        self._sock.settimeout(5.0)

    def send_recv(self, payload: bytes) -> bytes:
        """Send payload and read one newline-terminated response. Reconnects once on failure."""
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
                        print(f"[cmux-proxy] reconnecting: {e}", file=sys.stderr)
                        try:
                            if self._sock:
                                self._sock.close()
                        except Exception:
                            pass
                        self._sock = None
                    else:
                        raise
            return b""


# -- Claude hook protocol (inline) --------------------------------------------
# Replaces subprocess calls to `cmux claude-hook`. The CLI sends these
# commands over the socket (traced via protocol interception):
#
#   session-start: surface.list → set_agent_pid claude_code <pid>
#   stop/idle:     surface.list → set_status claude_code Idle
#   notification:  surface.list → notify_target <ws> <surface> ... → set_status
#   prompt-submit: surface.list → clear_notifications → set_status Running
#   session-end:   surface.list → clear_status claude_code


# Safe cmux identifier pattern: UUIDs and short refs like "workspace:2".
# Accepts hex, hyphens, colons, and digits — rejects whitespace, pipes, and
# anything that could break out of a text-protocol token.
_CMUX_ID_RE = re.compile(r"^[A-Za-z0-9:_-]{1,128}$")


def _safe_cmux_id(value: Optional[str]) -> Optional[str]:
    """Validate a cmux identifier. Returns None if unsafe.

    cmux IDs come from untrusted sources (response payloads, env vars).
    Anything containing whitespace, newlines, or pipe chars would be
    interpreted as command separators in cmux's text protocol.
    """
    if not value or not isinstance(value, str):
        return None
    return value if _CMUX_ID_RE.match(value) else None


def _sanitize_text_arg(value: str) -> str:
    """Neutralize characters that would break cmux's text protocol.

    The text protocol is line-based and pipe-delimited for notification
    arguments. Collapse newlines, CR, and pipes to spaces.
    """
    return value.replace("|", " ").replace("\n", " ").replace("\r", " ")


def _get_surface_id(cmux: CmuxConnection, workspace_id: str) -> Optional[str]:
    """Get the first surface ID in the workspace for targeted notifications.

    The returned ID is validated against _CMUX_ID_RE — a malicious cmux
    response cannot inject protocol commands through this path.
    """
    try:
        msg = (
            json.dumps(
                {
                    "method": "surface.list",
                    "params": {"workspace_id": workspace_id},
                    "id": str(uuid.uuid4()),
                }
            )
            + "\n"
        )
        resp = cmux.send_recv(msg.encode())
        data = json.loads(resp.decode())
        surfaces = data.get("result", [])
        if surfaces and isinstance(surfaces, list):
            raw_id = surfaces[0].get("id") if isinstance(surfaces[0], dict) else None
            return _safe_cmux_id(raw_id)
    except Exception:
        pass
    return None


def _handle_claude_hook(
    event: str, params: dict, workspace_id: str, cmux: CmuxConnection
) -> bool:
    """Handle a claude-hook event by sending cmux protocol commands directly."""
    # workspace_id comes from CMUX_WORKSPACE_ID env var — validate before
    # splicing into text-protocol commands to prevent command injection.
    safe_workspace = _safe_cmux_id(workspace_id)
    tab = f"--tab={safe_workspace}" if safe_workspace else ""
    try:
        if event in ("session-start", "active"):
            cmux.send_recv(
                f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF {tab}\n".encode()
            )
        elif event in ("stop", "idle"):
            cmux.send_recv(
                f"set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 {tab}\n".encode()
            )
        elif event in ("notification", "notify"):
            title = params.get("title", "Claude Code")
            body = params.get("body", "")
            # Targeted notification to the specific surface. All variable
            # components are validated/sanitized before splicing into text
            # protocol to prevent command injection from cmux responses or
            # hook payloads.
            surface_id = _get_surface_id(cmux, workspace_id)
            if surface_id and safe_workspace:
                safe_title = _sanitize_text_arg(title)
                safe_body = _sanitize_text_arg(body)
                cmux.send_recv(
                    f"notify_target {safe_workspace} {surface_id} {safe_title}|Attention|{safe_body}\n".encode()
                )
            cmux.send_recv(
                f"set_status claude_code Needs\\ input --icon=bell.fill --color=#4C8DFF {tab}\n".encode()
            )
        elif event == "prompt-submit":
            cmux.send_recv(f"clear_notifications {tab}\n".encode())
            cmux.send_recv(
                f"set_status claude_code Running --icon=bolt.fill --color=#4C8DFF {tab}\n".encode()
            )
        elif event == "session-end":
            cmux.send_recv(f"clear_status claude_code {tab}\n".encode())
        else:
            return True  # Unknown but allowed event — no-op.
        return True
    except Exception as e:
        print(f"[cmux-proxy] claude-hook {event} failed: {e}", file=sys.stderr)
        return False


# -- Connection handling -------------------------------------------------------


def make_error_response(req_id: Optional[str], message: str) -> str:
    return json.dumps({"id": req_id, "ok": False, "error": message})


def _is_json(line: str) -> bool:
    return line.lstrip().startswith("{")


def _inject_workspace_text(line: str, workspace_id: str) -> str:
    """Rewrite --tab= / --workspace= flags to the given (trusted) workspace.

    Any client-supplied --tab/--workspace flags are stripped first so a
    compromised container sidecar cannot target arbitrary workspaces.
    workspace_id is validated — an unsafe value yields no flag.
    """
    # Strip any existing --tab= or --workspace= flags.
    line = re.sub(r"\s+--(?:tab|workspace)=\S+", "", line).strip()
    safe = _safe_cmux_id(workspace_id)
    if not safe:
        return line
    return f"{line} --tab={safe}"


def _inject_workspace_json(msg: dict, workspace_id: str) -> dict:
    """Overwrite params.workspace_id with the trusted value.

    Any client-supplied workspace_id is replaced, not preserved — otherwise
    a compromised sidecar could target arbitrary workspaces.
    """
    params = msg.get("params") or {}
    safe = _safe_cmux_id(workspace_id)
    if safe:
        params["workspace_id"] = safe
    elif "workspace_id" in params:
        # No trusted value to inject, but remove any untrusted one.
        del params["workspace_id"]
    msg["params"] = params
    return msg


_TAB_FLAG_EXTRACT = re.compile(r"--(?:tab|workspace)=(\S+)")


def _extract_workspace_from_text(line: str) -> str:
    """Extract the first --tab=VALUE or --workspace=VALUE from a text command.

    Returns empty string if none found. The caller must validate via
    _safe_cmux_id before using.
    """
    m = _TAB_FLAG_EXTRACT.search(line)
    return m.group(1) if m else ""


def handle_client(
    client: socket.socket,
    fallback_workspace_id: str,
    cmux: CmuxConnection,
) -> None:
    """Handle a single TCP client connection.

    Each request carries its own workspace_id (from the devbox sidecar that
    is bound to a specific devbox session). fallback_workspace_id is used
    only when the request has none (e.g., manual testing from the shell).
    """
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
                    try:
                        msg = json.loads(line_str)
                        method = msg.get("method", "")
                        req_id = msg.get("id")
                    except (json.JSONDecodeError, AttributeError):
                        resp = make_error_response(None, "invalid JSON")
                        client.sendall((resp + "\n").encode())
                        continue

                    # Per-request workspace: trust sidecar > fallback to host env.
                    req_params = msg.get("params") or {}
                    req_ws = (
                        req_params.get("workspace_id", "")
                        if isinstance(req_params, dict)
                        else ""
                    )
                    effective_ws = _safe_cmux_id(req_ws) or fallback_workspace_id

                    if is_json_method_allowed(method):
                        if method.startswith("claude-hook."):
                            event = method.removeprefix("claude-hook.")
                            if event not in ALLOWED_CLAUDE_HOOK_EVENTS:
                                resp = make_error_response(
                                    req_id, f"unknown event: {event}"
                                )
                                client.sendall((resp + "\n").encode())
                            else:
                                ok = _handle_claude_hook(
                                    event, req_params, effective_ws, cmux
                                )
                                resp = json.dumps({"id": req_id, "ok": ok})
                                client.sendall((resp + "\n").encode())
                        else:
                            msg = _inject_workspace_json(msg, effective_ws)
                            forwarded = json.dumps(msg).encode() + b"\n"
                            try:
                                cmux_resp = cmux.send_recv(forwarded)
                                client.sendall(cmux_resp)
                            except (OSError, ConnectionError):
                                client.sendall(
                                    make_error_response(
                                        req_id, "cmux unavailable"
                                    ).encode()
                                    + b"\n"
                                )
                    else:
                        print(f"[cmux-proxy] blocked: {method}", file=sys.stderr)
                        resp = make_error_response(
                            req_id, f"method '{method}' blocked by devbox proxy"
                        )
                        client.sendall((resp + "\n").encode())
                else:
                    # Per-request workspace from --tab= flag, else host env.
                    req_ws = _extract_workspace_from_text(line_str)
                    effective_ws = _safe_cmux_id(req_ws) or fallback_workspace_id

                    if is_text_command_allowed(line_str):
                        line_str = _inject_workspace_text(line_str, effective_ws)
                        try:
                            cmux_resp = cmux.send_recv((line_str + "\n").encode())
                            client.sendall(cmux_resp)
                        except (OSError, ConnectionError):
                            client.sendall(b"ERR: cmux unavailable\n")
                    else:
                        command = line_str.split()[0] if line_str else "(empty)"
                        print(f"[cmux-proxy] blocked: {command}", file=sys.stderr)
                        client.sendall(b"ERR: command blocked by devbox proxy\n")
    except (OSError, ConnectionError) as exc:
        print(f"[cmux-proxy] client disconnected: {exc}", file=sys.stderr)
    finally:
        client.close()


# -- Main ----------------------------------------------------------------------


def _detach_from_terminal() -> None:
    """Detach from the controlling terminal so we survive shell exit.

    setsid() creates a new session with the proxy as leader. This makes
    the proxy immune to SIGHUP when the spawning shell closes its
    controlling terminal — we're no longer part of that terminal's session.

    Must be called BEFORE the cmux socket connect (which inherits process
    lineage at connect time). cmux auth still works because the new session
    inherits the parent's ancestry up to cmux.
    """
    try:
        os.setsid()
    except OSError:
        # Already a session leader (e.g. if spawned via setsid/nohup on Linux).
        pass
    # Ignore SIGHUP just in case (belt and suspenders).
    signal.signal(signal.SIGHUP, signal.SIG_IGN)


def main() -> None:
    cmux_socket_path = os.environ.get("CMUX_SOCKET_PATH", "")
    if not cmux_socket_path:
        print("[cmux-proxy] CMUX_SOCKET_PATH not set, exiting", file=sys.stderr)
        sys.exit(1)

    if not Path(cmux_socket_path).exists():
        print(f"[cmux-proxy] socket not found: {cmux_socket_path}", file=sys.stderr)
        sys.exit(1)

    # Detach from controlling terminal before anything else.
    _detach_from_terminal()

    workspace_id = os.environ.get("CMUX_WORKSPACE_ID", "")

    # Connect to cmux socket.
    cmux_conn = CmuxConnection(cmux_socket_path)
    try:
        cmux_conn.connect()
    except OSError as e:
        print(f"[cmux-proxy] failed to connect to cmux: {e}", file=sys.stderr)
        sys.exit(1)

    # Bind TCP listener.
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((LISTEN_HOST, LISTEN_PORT))
    server.listen(8)
    server.settimeout(1.0)

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))

    print(f"[cmux-proxy] listening on {LISTEN_HOST}:{LISTEN_PORT}", file=sys.stderr)
    if workspace_id:
        print(f"[cmux-proxy] workspace: {workspace_id}", file=sys.stderr)

    while True:
        try:
            client, _ = server.accept()
            t = threading.Thread(
                target=handle_client,
                args=(client, workspace_id, cmux_conn),
                daemon=True,
            )
            t.start()
        except socket.timeout:
            pass
        except OSError as e:
            print(f"[cmux-proxy] server error: {e}", file=sys.stderr)
            break
        except Exception as e:
            print(f"[cmux-proxy] unexpected error: {e}", file=sys.stderr)

    server.close()


if __name__ == "__main__":
    main()
