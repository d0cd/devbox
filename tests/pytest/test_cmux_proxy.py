"""Tests for tooling/cmux-proxy.py command filtering."""

import importlib.util
import json
import sys
from pathlib import Path

# Add tooling directory to path so we can import the proxy module.
# The file is cmux-proxy.py (hyphenated for CLI convention), so we use
# importlib to handle the non-standard module name.
TOOLING_DIR = Path(__file__).resolve().parent.parent.parent / "tooling"
_spec = importlib.util.spec_from_file_location("cmux_proxy", TOOLING_DIR / "cmux-proxy.py")
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


class TestTextCommandAllowed:
    """Tests for text-protocol sidebar command filtering."""

    def test_set_status_allowed(self):
        assert is_text_command_allowed("set_status claude working")

    def test_clear_status_allowed(self):
        assert is_text_command_allowed("clear_status claude")

    def test_list_status_allowed(self):
        assert is_text_command_allowed("list_status")

    def test_set_progress_allowed(self):
        assert is_text_command_allowed("set_progress 0.5")

    def test_clear_progress_allowed(self):
        assert is_text_command_allowed("clear_progress")

    def test_log_allowed(self):
        assert is_text_command_allowed("log -- Build started")

    def test_clear_log_allowed(self):
        assert is_text_command_allowed("clear_log")

    def test_list_log_allowed(self):
        assert is_text_command_allowed("list_log")

    def test_sidebar_state_allowed(self):
        assert is_text_command_allowed("sidebar_state")

    def test_send_blocked(self):
        assert not is_text_command_allowed("send echo hello")

    def test_send_key_blocked(self):
        assert not is_text_command_allowed("send_key ctrl+c")

    def test_read_screen_blocked(self):
        assert not is_text_command_allowed("read_screen --scrollback")

    def test_empty_blocked(self):
        assert not is_text_command_allowed("")

    def test_unknown_blocked(self):
        assert not is_text_command_allowed("new_workspace --cwd /")

    def test_set_status_with_flags(self):
        assert is_text_command_allowed("set_status branch main --icon=arrow.triangle.branch")

    def test_set_status_with_tab(self):
        assert is_text_command_allowed("set_status claude idle --tab=ABC-123")


class TestJsonMethodAllowed:
    """Tests for JSON-RPC method filtering."""

    def test_notification_create_allowed(self):
        assert is_json_method_allowed("notification.create")

    def test_notification_list_allowed(self):
        assert is_json_method_allowed("notification.list")

    def test_notification_clear_allowed(self):
        assert is_json_method_allowed("notification.clear")

    def test_notification_create_for_surface_allowed(self):
        assert is_json_method_allowed("notification.create_for_surface")

    def test_notification_create_for_target_allowed(self):
        assert is_json_method_allowed("notification.create_for_target")

    def test_system_ping_allowed(self):
        assert is_json_method_allowed("system.ping")

    def test_system_capabilities_allowed(self):
        assert is_json_method_allowed("system.capabilities")

    def test_system_identify_allowed(self):
        assert is_json_method_allowed("system.identify")

    def test_surface_send_text_blocked(self):
        assert not is_json_method_allowed("surface.send_text")

    def test_surface_send_key_blocked(self):
        assert not is_json_method_allowed("surface.send_key")

    def test_surface_read_text_blocked(self):
        assert not is_json_method_allowed("surface.read_text")

    def test_workspace_create_blocked(self):
        assert not is_json_method_allowed("workspace.create")

    def test_workspace_close_blocked(self):
        assert not is_json_method_allowed("workspace.close")

    def test_browser_navigate_blocked(self):
        assert not is_json_method_allowed("browser.navigate")

    def test_browser_eval_blocked(self):
        assert not is_json_method_allowed("browser.eval")

    def test_empty_blocked(self):
        assert not is_json_method_allowed("")

    def test_unknown_blocked(self):
        assert not is_json_method_allowed("unknown.method")


class TestIsMethodAllowed:
    """Tests for the unified is_method_allowed (backwards compat)."""

    def test_text_command_passes(self):
        assert is_method_allowed("set_status")

    def test_json_method_passes(self):
        assert is_method_allowed("notification.create")

    def test_blocked_text(self):
        assert not is_method_allowed("send")

    def test_blocked_json(self):
        assert not is_method_allowed("surface.send_text")

    def test_empty(self):
        assert not is_method_allowed("")

    def test_prefix_match_works(self):
        assert is_method_allowed("system.ping")
        assert is_method_allowed("notification.create")

    def test_browser_prefix_blocked(self):
        """browser.* is not in allowed prefixes."""
        assert not is_method_allowed("browser.navigate")


class TestIsJson:
    """Tests for JSON vs text detection."""

    def test_json_object(self):
        assert _is_json('{"method":"test"}')

    def test_json_with_whitespace(self):
        assert _is_json('  {"method":"test"}')

    def test_text_command(self):
        assert not _is_json("set_status claude working")

    def test_empty(self):
        assert not _is_json("")


class TestInjectWorkspaceText:
    """Tests for text-protocol workspace injection."""

    def test_injects_tab(self):
        result = _inject_workspace_text("set_status claude working", "ABC-123")
        assert result == "set_status claude working --tab=ABC-123"

    def test_preserves_existing_tab(self):
        result = _inject_workspace_text("set_status claude working --tab=EXISTING", "ABC-123")
        assert "--tab=EXISTING" in result
        assert "--tab=ABC-123" not in result


class TestInjectWorkspaceJson:
    """Tests for JSON-RPC workspace injection."""

    def test_injects_workspace_id(self):
        msg = {"method": "notification.create", "params": {"title": "test"}}
        result = _inject_workspace_json(msg, "ABC-123")
        assert result["params"]["workspace_id"] == "ABC-123"

    def test_preserves_existing_workspace_id(self):
        msg = {"method": "notification.create", "params": {"workspace_id": "EXISTING"}}
        result = _inject_workspace_json(msg, "ABC-123")
        assert result["params"]["workspace_id"] == "EXISTING"

    def test_creates_params_if_missing(self):
        msg = {"method": "notification.create"}
        result = _inject_workspace_json(msg, "ABC-123")
        assert result["params"]["workspace_id"] == "ABC-123"


class TestMakeErrorResponse:
    """Tests for error response generation."""

    def test_error_response_has_id(self):
        resp = make_error_response("req-1", "blocked")
        parsed = json.loads(resp)
        assert parsed["id"] == "req-1"

    def test_error_response_has_ok_false(self):
        resp = make_error_response("req-1", "blocked")
        parsed = json.loads(resp)
        assert parsed["ok"] is False

    def test_error_response_has_message(self):
        resp = make_error_response("req-1", "method blocked by devbox proxy")
        parsed = json.loads(resp)
        assert "blocked" in parsed["error"]

    def test_error_response_null_id(self):
        resp = make_error_response(None, "blocked")
        parsed = json.loads(resp)
        assert parsed["id"] is None
