"""Tests for tooling/cmux-proxy.py command filtering and security boundaries."""

import importlib.util
import json
from pathlib import Path

import pytest

TOOLING_DIR = Path(__file__).resolve().parent.parent.parent / "tooling"
_spec = importlib.util.spec_from_file_location(
    "cmux_proxy", TOOLING_DIR / "cmux-proxy.py"
)
assert _spec and _spec.loader
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)

is_text_command_allowed = _mod.is_text_command_allowed
is_json_method_allowed = _mod.is_json_method_allowed
make_error_response = _mod.make_error_response
_inject_workspace_text = _mod._inject_workspace_text
_inject_workspace_json = _mod._inject_workspace_json
_is_json = _mod._is_json
_safe_cmux_id = _mod._safe_cmux_id
_sanitize_text_arg = _mod._sanitize_text_arg
ALLOWED_TEXT_COMMANDS = _mod.ALLOWED_TEXT_COMMANDS
ALLOWED_JSON_METHODS = _mod.ALLOWED_JSON_METHODS
ALLOWED_CLAUDE_HOOK_EVENTS = _mod.ALLOWED_CLAUDE_HOOK_EVENTS


class TestTextCommandFiltering:
    """Text-protocol command allowlist."""

    @pytest.mark.parametrize("cmd", list(ALLOWED_TEXT_COMMANDS))
    def test_allowed_commands(self, cmd):
        assert is_text_command_allowed(f"{cmd} arg1 arg2")

    @pytest.mark.parametrize(
        "cmd", ["send", "send_key", "read_screen", "new_workspace", "close_workspace"]
    )
    def test_blocked_commands(self, cmd):
        assert not is_text_command_allowed(f"{cmd} arg")

    def test_empty_blocked(self):
        assert not is_text_command_allowed("")

    def test_flags_dont_affect_check(self):
        assert is_text_command_allowed(
            "set_status claude working --icon=bolt.fill --tab=ABC"
        )


class TestJsonMethodFiltering:
    """JSON-RPC method allowlist."""

    @pytest.mark.parametrize("method", list(ALLOWED_JSON_METHODS))
    def test_allowed_methods(self, method):
        assert is_json_method_allowed(method)

    @pytest.mark.parametrize(
        "method",
        ["surface.send_text", "workspace.create", "browser.navigate", "browser.eval"],
    )
    def test_blocked_methods(self, method):
        assert not is_json_method_allowed(method)

    def test_empty_blocked(self):
        assert not is_json_method_allowed("")

    def test_claude_hook_prefix_allowed(self):
        assert is_json_method_allowed("claude-hook.stop")
        assert is_json_method_allowed("claude-hook.notification")


class TestClaudeHookEventAllowlist:
    """The claude-hook event boundary — restricts which events reach cmux CLI."""

    @pytest.mark.parametrize("event", list(ALLOWED_CLAUDE_HOOK_EVENTS))
    def test_allowed_events(self, event):
        assert event in ALLOWED_CLAUDE_HOOK_EVENTS

    @pytest.mark.parametrize("event", ["exec", "shell", "rm", "../../bin/sh"])
    def test_blocked_events(self, event):
        assert event not in ALLOWED_CLAUDE_HOOK_EVENTS


class TestIsJson:
    """JSON vs text protocol detection."""

    def test_json_object(self):
        assert _is_json('{"method":"test"}')

    def test_text_command(self):
        assert not _is_json("set_status claude working")

    def test_empty(self):
        assert not _is_json("")


class TestWorkspaceInjection:
    """Workspace ID injection for both protocols."""

    def test_text_injects_tab(self):
        result = _inject_workspace_text("set_status claude working", "ABC-123")
        assert result == "set_status claude working --tab=ABC-123"

    def test_text_overrides_existing_tab(self):
        """Existing --tab= is treated as untrusted and replaced."""
        result = _inject_workspace_text("set_status claude --tab=EXISTING", "ABC-123")
        assert "--tab=EXISTING" not in result
        assert "--tab=ABC-123" in result

    def test_json_injects_workspace_id(self):
        msg = {"method": "notification.create", "params": {"title": "test"}}
        result = _inject_workspace_json(msg, "ABC-123")
        assert result["params"]["workspace_id"] == "ABC-123"

    def test_json_overrides_existing_workspace_id(self):
        """Existing workspace_id is treated as untrusted and replaced."""
        msg = {"params": {"workspace_id": "EXISTING"}}
        result = _inject_workspace_json(msg, "ABC-123")
        assert result["params"]["workspace_id"] == "ABC-123"

    def test_json_creates_params_if_missing(self):
        msg = {"method": "test"}
        result = _inject_workspace_json(msg, "ABC-123")
        assert result["params"]["workspace_id"] == "ABC-123"


class TestSafeCmuxId:
    """_safe_cmux_id guards against protocol injection via untrusted IDs."""

    @pytest.mark.parametrize(
        "value",
        [
            "755810AA-4CF5-443A-805E-AA28EC4A0618",  # UUID
            "workspace:2",                            # Short ref
            "abc_def-123",
            "A1B2",
        ],
    )
    def test_accepts_valid(self, value):
        assert _safe_cmux_id(value) == value

    @pytest.mark.parametrize(
        "value",
        [
            "abc def",               # space
            "abc\nset_status evil",  # newline injection
            "abc\tpipe",              # tab
            "abc|pipe",               # pipe char
            "abc\r",                  # carriage return
            "",                       # empty
            None,                     # None
            123,                      # wrong type
            "a" * 200,                # too long (>128)
            "abc;rm -rf /",           # shell injection attempt
        ],
    )
    def test_rejects_unsafe(self, value):
        assert _safe_cmux_id(value) is None


class TestSanitizeTextArg:
    """_sanitize_text_arg neutralizes text-protocol separators."""

    def test_replaces_pipe(self):
        assert "|" not in _sanitize_text_arg("foo|bar")

    def test_replaces_newline(self):
        assert "\n" not in _sanitize_text_arg("foo\nbar")

    def test_replaces_cr(self):
        assert "\r" not in _sanitize_text_arg("foo\rbar")

    def test_preserves_safe_chars(self):
        assert _sanitize_text_arg("Hello, world!") == "Hello, world!"


class TestWorkspaceInjectionSecurity:
    """Workspace ID injection must not enable protocol injection."""

    def test_rejects_newline_in_workspace(self):
        result = _inject_workspace_text("set_status claude Running", "abc\nset_status evil")
        assert "\n" not in result.replace("set_status claude Running", "")
        # Unsafe workspace falls back to no injection.
        assert result == "set_status claude Running"

    def test_rejects_space_in_workspace(self):
        result = _inject_workspace_text("set_status claude Running", "abc def")
        assert result == "set_status claude Running"

    def test_strips_client_supplied_tab(self):
        """A compromised client cannot override the workspace via --tab=."""
        result = _inject_workspace_text(
            "set_status claude Running --tab=EVIL_WORKSPACE", "TRUSTED_WS"
        )
        assert "EVIL_WORKSPACE" not in result
        assert "--tab=TRUSTED_WS" in result

    def test_strips_client_supplied_workspace_flag(self):
        """Strips --workspace= too (not just --tab=)."""
        result = _inject_workspace_text(
            "notify_target W S title|x|y --workspace=EVIL", "TRUSTED_WS"
        )
        assert "EVIL" not in result
        assert "--tab=TRUSTED_WS" in result

    def test_json_override_replaces_client_workspace(self):
        """A client-supplied params.workspace_id is replaced, not preserved."""
        msg = {"params": {"workspace_id": "EVIL_WS", "title": "x"}}
        result = _inject_workspace_json(msg, "TRUSTED_WS")
        assert result["params"]["workspace_id"] == "TRUSTED_WS"

    def test_json_strips_untrusted_workspace_when_no_fallback(self):
        """If trusted workspace is empty, a client-supplied one is removed."""
        msg = {"params": {"workspace_id": "SOMETHING"}}
        result = _inject_workspace_json(msg, "")
        assert "workspace_id" not in result["params"]


class TestMakeErrorResponse:
    """Error response formatting."""

    def test_has_required_fields(self):
        resp = json.loads(make_error_response("req-1", "blocked"))
        assert resp["id"] == "req-1"
        assert resp["ok"] is False
        assert "blocked" in resp["error"]

    def test_null_id(self):
        resp = json.loads(make_error_response(None, "error"))
        assert resp["id"] is None
