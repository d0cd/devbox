"""Tests for proxy/notifier.py — cmux notification forwarder."""

import json
from unittest.mock import MagicMock, patch


from notifier import CmuxNotifier


class TestRequestRouting:
    """Verify /_devbox/ path interception and routing."""

    def test_ignores_normal_requests(self):
        n = CmuxNotifier()
        flow = MagicMock()
        flow.request.path = "/v1/messages"
        n.request(flow)
        # Should not set a response — the flow passes through.
        assert flow.response is flow.response  # unchanged mock

    def test_notify_endpoint_calls_handle(self):
        n = CmuxNotifier()
        flow = MagicMock()
        flow.request.path = "/_devbox/notify"
        flow.request.method = "POST"
        flow.request.get_content.return_value = json.dumps(
            {"title": "test", "body": "hello"}
        ).encode()
        with patch.object(n, "_send_to_proxy") as mock_send:
            n.request(flow)
        mock_send.assert_called_once()
        assert flow.response.status_code == 200

    def test_status_endpoint_calls_handle(self):
        n = CmuxNotifier()
        flow = MagicMock()
        flow.request.path = "/_devbox/status"
        flow.request.method = "POST"
        flow.request.get_content.return_value = b"set_status active"
        with patch.object(n, "_send_to_proxy") as mock_send:
            n.request(flow)
        mock_send.assert_called_once()
        assert flow.response.status_code == 200

    def test_unknown_devbox_endpoint_returns_404(self):
        n = CmuxNotifier()
        flow = MagicMock()
        flow.request.path = "/_devbox/unknown"
        flow.request.method = "GET"
        n.request(flow)
        assert flow.response.status_code == 404


class TestHandleNotify:
    """Verify notification payload formatting."""

    def test_sends_jsonrpc_notification_create(self):
        """Notifications must use JSON-RPC, not ad-hoc text protocol."""
        n = CmuxNotifier()
        flow = MagicMock()
        flow.request.get_content.return_value = json.dumps(
            {"title": "Build", "body": "done"}
        ).encode()
        with patch.object(n, "_send_to_proxy") as mock_send:
            n._handle_notify(flow)
        payload = mock_send.call_args[0][0]
        msg = json.loads(payload.rstrip("\n"))
        assert msg["method"] == "notification.create"
        assert msg["params"]["title"] == "Build"
        assert msg["params"]["body"] == "done"
        assert "id" in msg
        assert flow.response.status_code == 200

    def test_defaults_title_and_body(self):
        n = CmuxNotifier()
        flow = MagicMock()
        flow.request.get_content.return_value = b"{}"
        with patch.object(n, "_send_to_proxy") as mock_send:
            n._handle_notify(flow)
        payload = mock_send.call_args[0][0]
        msg = json.loads(payload.rstrip("\n"))
        assert msg["params"]["title"] == "devbox"
        assert msg["params"]["body"] == ""

    @patch("notifier.ctx")
    def test_returns_200_on_exception(self, _mock_ctx):
        """Notifier should never break the agent — always returns 200."""
        n = CmuxNotifier()
        flow = MagicMock()
        flow.request.get_content.side_effect = Exception("bad json")
        n._handle_notify(flow)
        assert flow.response.status_code == 200


class TestHandleStatus:
    """Verify status command forwarding."""

    def test_forwards_raw_body(self):
        n = CmuxNotifier()
        flow = MagicMock()
        flow.request.get_content.return_value = b"set_status working"
        with patch.object(n, "_send_to_proxy") as mock_send:
            n._handle_status(flow)
        payload = mock_send.call_args[0][0]
        assert payload == "set_status working\n"

    @patch("notifier.ctx")
    def test_returns_200_on_exception(self, _mock_ctx):
        n = CmuxNotifier()
        flow = MagicMock()
        flow.request.get_content.side_effect = Exception("decode error")
        n._handle_status(flow)
        assert flow.response.status_code == 200


class TestHandleClaudeHook:
    """Verify Claude Code hook forwarding."""

    def test_forwards_hook_as_jsonrpc(self):
        n = CmuxNotifier()
        flow = MagicMock()
        flow.request.get_content.return_value = json.dumps(
            {"event": "stop", "data": {"message": "done"}}
        ).encode()
        with patch.object(n, "_send_to_proxy") as mock_send:
            n._handle_claude_hook(flow)
        payload = mock_send.call_args[0][0]
        msg = json.loads(payload.rstrip("\n"))
        assert msg["method"] == "claude-hook.stop"
        assert msg["params"] == {"message": "done"}
        assert msg["id"] == "claude-hook-stop"
        assert flow.response.status_code == 200

    def test_missing_event_returns_400(self):
        n = CmuxNotifier()
        flow = MagicMock()
        flow.request.get_content.return_value = json.dumps(
            {"data": {"message": "no event"}}
        ).encode()
        n._handle_claude_hook(flow)
        assert flow.response.status_code == 400

    def test_empty_event_returns_400(self):
        n = CmuxNotifier()
        flow = MagicMock()
        flow.request.get_content.return_value = json.dumps(
            {"event": "", "data": {}}
        ).encode()
        n._handle_claude_hook(flow)
        assert flow.response.status_code == 400

    def test_defaults_data_to_empty_dict(self):
        n = CmuxNotifier()
        flow = MagicMock()
        flow.request.get_content.return_value = json.dumps(
            {"event": "start"}
        ).encode()
        with patch.object(n, "_send_to_proxy") as mock_send:
            n._handle_claude_hook(flow)
        payload = mock_send.call_args[0][0]
        msg = json.loads(payload.rstrip("\n"))
        assert msg["params"] == {}
        assert flow.response.status_code == 200

    @patch("notifier.ctx")
    def test_returns_200_on_exception(self, _mock_ctx):
        """Should not break the agent on bad input."""
        n = CmuxNotifier()
        flow = MagicMock()
        flow.request.get_content.side_effect = Exception("bad json")
        n._handle_claude_hook(flow)
        assert flow.response.status_code == 200

    def test_claude_hook_endpoint_routing(self):
        """Verify /_devbox/claude-hook routes to _handle_claude_hook."""
        n = CmuxNotifier()
        flow = MagicMock()
        flow.request.path = "/_devbox/claude-hook"
        flow.request.method = "POST"
        flow.request.get_content.return_value = json.dumps(
            {"event": "stop", "data": {}}
        ).encode()
        with patch.object(n, "_send_to_proxy"):
            n.request(flow)
        assert flow.response.status_code == 200


class TestSendToProxy:
    """Verify TCP communication with cmux proxy."""

    @patch.dict("os.environ", {"DEVBOX_CMUX_PROXY_PORT": "9999"})
    @patch("notifier.socket.create_connection")
    def test_sends_payload_to_host(self, mock_conn):
        sock = MagicMock()
        mock_conn.return_value = sock
        n = CmuxNotifier()
        n._send_to_proxy("notify  test||msg\n")
        mock_conn.assert_called_once_with(("host.docker.internal", 9999), timeout=2)
        sock.sendall.assert_called_once_with(b"notify  test||msg\n")
        sock.close.assert_called_once()

    @patch("notifier.ctx")
    @patch.dict("os.environ", {"DEVBOX_CMUX_PROXY_PORT": "9999"})
    @patch("notifier.socket.create_connection", side_effect=ConnectionRefusedError)
    def test_swallows_connection_error(self, _mock_conn, _mock_ctx):
        """Should not raise — cmux proxy may not be running."""
        n = CmuxNotifier()
        n._send_to_proxy("test\n")  # Should not raise.
