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
is_method_allowed = _mod.is_method_allowed
make_error_response = _mod.make_error_response
_inject_workspace_text = _mod._inject_workspace_text
_inject_workspace_json = _mod._inject_workspace_json
_is_json = _mod._is_json
ALLOWED_TEXT_COMMANDS = _mod.ALLOWED_TEXT_COMMANDS
ALLOWED_JSON_METHODS = _mod.ALLOWED_JSON_METHODS
ALLOWED_CLAUDE_HOOK_EVENTS = _mod.ALLOWED_CLAUDE_HOOK_EVENTS


class TestTextCommandFiltering:
    """Text-protocol command allowlist."""

    @pytest.mark.parametrize("cmd", list(ALLOWED_TEXT_COMMANDS))
    def test_allowed_commands(self, cmd):
        assert is_text_command_allowed(f"{cmd} arg1 arg2")

    @pytest.mark.parametrize("cmd", ["send", "send_key", "read_screen", "new_workspace", "close_workspace"])
    def test_blocked_commands(self, cmd):
        assert not is_text_command_allowed(f"{cmd} arg")

    def test_empty_blocked(self):
        assert not is_text_command_allowed("")

    def test_flags_dont_affect_check(self):
        assert is_text_command_allowed("set_status claude working --icon=bolt.fill --tab=ABC")


class TestJsonMethodFiltering:
    """JSON-RPC method allowlist."""

    @pytest.mark.parametrize("method", list(ALLOWED_JSON_METHODS))
    def test_allowed_methods(self, method):
        assert is_json_method_allowed(method)

    @pytest.mark.parametrize("method", ["surface.send_text", "workspace.create", "browser.navigate", "browser.eval"])
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

    def test_text_preserves_existing_tab(self):
        result = _inject_workspace_text("set_status claude --tab=EXISTING", "ABC-123")
        assert "--tab=EXISTING" in result
        assert "--tab=ABC-123" not in result

    def test_json_injects_workspace_id(self):
        msg = {"method": "notification.create", "params": {"title": "test"}}
        result = _inject_workspace_json(msg, "ABC-123")
        assert result["params"]["workspace_id"] == "ABC-123"

    def test_json_preserves_existing_workspace_id(self):
        msg = {"params": {"workspace_id": "EXISTING"}}
        result = _inject_workspace_json(msg, "ABC-123")
        assert result["params"]["workspace_id"] == "EXISTING"

    def test_json_creates_params_if_missing(self):
        msg = {"method": "test"}
        result = _inject_workspace_json(msg, "ABC-123")
        assert result["params"]["workspace_id"] == "ABC-123"


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
