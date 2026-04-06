"""Tests for proxy/enforcer.py."""

import time
from unittest.mock import MagicMock, patch

from enforcer import (
    Enforcer,
    _is_allowed,
    _load_allowlist,
)


class TestLoadAllowlist:
    """Tests for _load_allowlist()."""

    def test_loads_valid_policy(self, temp_policy):
        result = _load_allowlist(temp_policy)
        assert "api.anthropic.com" in result
        assert "*.openai.com" in result

    def test_missing_file_returns_empty(self, tmp_path):
        result = _load_allowlist(tmp_path / "nonexistent.yml")
        assert result == []

    def test_invalid_yaml_returns_empty(self, tmp_path):
        bad = tmp_path / "bad.yml"
        bad.write_text("not: a: valid: yaml: list")
        result = _load_allowlist(bad)
        assert result == []

    def test_missing_allowed_key_returns_empty(self, tmp_path):
        no_key = tmp_path / "no_allowed.yml"
        no_key.write_text("version: 1\nblocked:\n  - evil.com\n")
        result = _load_allowlist(no_key)
        assert result == []

    def test_rejects_mid_string_wildcard(self, tmp_path):
        policy = tmp_path / "wild.yml"
        policy.write_text("allowed:\n  - ex*ample.com\n  - good.com\n")
        result = _load_allowlist(policy)
        assert "ex*ample.com" not in result
        assert "good.com" in result

    def test_lowercases_entries(self, tmp_path):
        policy = tmp_path / "case.yml"
        policy.write_text("allowed:\n  - API.Example.COM\n")
        result = _load_allowlist(policy)
        assert "api.example.com" in result


class TestIsAllowed:
    """Tests for _is_allowed()."""

    def test_exact_match(self):
        assert _is_allowed("api.anthropic.com", ["api.anthropic.com"])

    def test_exact_no_match(self):
        assert not _is_allowed("evil.com", ["api.anthropic.com"])

    def test_wildcard_matches_subdomain(self):
        assert _is_allowed("sub.example.com", ["*.example.com"])

    def test_wildcard_matches_base_domain(self):
        assert _is_allowed("example.com", ["*.example.com"])

    def test_wildcard_no_match(self):
        assert not _is_allowed("notexample.com", ["*.example.com"])

    def test_case_insensitive(self):
        assert _is_allowed("API.Anthropic.COM", ["api.anthropic.com"])

    def test_empty_allowlist_blocks_all(self):
        assert not _is_allowed("anything.com", [])

    def test_substring_not_matched(self):
        """Ensure 'evil.com' doesn't match 'notevil.com'."""
        assert not _is_allowed("notevil.com", ["evil.com"])

    def test_wildcard_deep_subdomain(self):
        assert _is_allowed("a.b.c.example.com", ["*.example.com"])

    def test_ip_address_not_matched(self):
        assert not _is_allowed("192.168.1.1", ["*.example.com", "api.test.com"])

    def test_empty_host_not_matched(self):
        assert not _is_allowed("", ["api.example.com"])


class TestLoadAllowlistEdgeCases:
    """Additional edge case tests for _load_allowlist()."""

    def test_oversized_policy_returns_empty(self, tmp_path):
        big = tmp_path / "big.yml"
        big.write_text("allowed:\n" + "  - x.com\n" * 200000)
        result = _load_allowlist(big)
        # File is ~2MB, above the 1MB threshold.
        assert result == []

    def test_non_list_allowed_returns_empty(self, tmp_path):
        bad = tmp_path / "notlist.yml"
        bad.write_text("allowed: just-a-string\n")
        result = _load_allowlist(bad)
        assert result == []

    def test_multi_wildcard_rejected(self, tmp_path):
        policy = tmp_path / "multi.yml"
        policy.write_text("allowed:\n  - '*.foo.*.com'\n  - good.com\n")
        result = _load_allowlist(policy)
        assert "*.foo.*.com" not in result
        assert "good.com" in result

    def test_unreadable_file_returns_empty(self, tmp_path):
        """OSError on open() should return empty list (fail-closed)."""
        policy = tmp_path / "noperm.yml"
        policy.write_text("allowed:\n  - good.com\n")
        policy.chmod(0o000)
        result = _load_allowlist(policy)
        assert result == []
        policy.chmod(0o644)  # Restore for cleanup.

    def test_numeric_entry_converted_to_string(self, tmp_path):
        policy = tmp_path / "num.yml"
        policy.write_text("allowed:\n  - 12345\n")
        result = _load_allowlist(policy)
        assert "12345" in result


class TestEnforcerClass:
    """Integration tests for the Enforcer mitmproxy addon."""

    def _make_enforcer(self, tmp_path, domains=None):
        """Create an Enforcer with a custom policy file."""
        policy = tmp_path / "policy.yml"
        if domains is None:
            domains = ["api.anthropic.com", "*.openai.com"]
        yaml_content = "allowed:\n" + "".join(f"  - '{d}'\n" for d in domains)
        policy.write_text(yaml_content)
        enforcer = Enforcer()
        with patch("enforcer.POLICY_PATH", policy), patch("enforcer.ctx") as _mock_ctx:
            enforcer._reload_policy()
        return enforcer

    def test_request_blocks_non_allowed(self, tmp_path):
        enforcer = self._make_enforcer(tmp_path)
        flow = MagicMock()
        flow.request.pretty_host = "evil.com"
        flow.request.path = "/v1/messages"
        flow.response = None
        with patch("enforcer.ctx"):
            enforcer.request(flow)
        # Enforcer should have set a 403 response with the domain name.
        assert flow.response is not None
        assert flow.response.status_code == 403
        assert b"evil.com" in flow.response.content

    def test_request_allows_matching_domain(self, tmp_path):
        enforcer = self._make_enforcer(tmp_path)
        flow = MagicMock()
        flow.request.pretty_host = "api.anthropic.com"
        flow.request.path = "/v1/messages"
        flow.response = None  # Not set by default.
        with patch("enforcer.ctx"):
            enforcer.request(flow)
        # Response should not be overridden for allowed domains.
        assert flow.response is None

    def test_http_connect_blocks_non_allowed(self, tmp_path):
        enforcer = self._make_enforcer(tmp_path)
        flow = MagicMock()
        flow.request.pretty_host = "evil.com"
        with patch("enforcer.ctx"):
            enforcer.http_connect(flow)
        assert flow.response is not None
        assert flow.response.status_code == 403
        assert b"evil.com" in flow.response.content

    def test_http_connect_allows_matching_domain(self, tmp_path):
        enforcer = self._make_enforcer(tmp_path)
        flow = MagicMock()
        flow.request.pretty_host = "sub.openai.com"
        flow.response = None
        with patch("enforcer.ctx"):
            enforcer.http_connect(flow)
        assert flow.response is None

    def test_request_blocks_with_empty_allowlist(self, tmp_path):
        """Empty allowlist (fail-closed) should block all traffic."""
        enforcer = self._make_enforcer(tmp_path, domains=[])
        flow = MagicMock()
        flow.request.pretty_host = "anything.com"
        flow.request.path = "/v1/messages"
        flow.response = None
        with patch("enforcer.ctx"):
            enforcer.request(flow)
        assert flow.response is not None
        assert flow.response.status_code == 403

    def test_maybe_reload_handles_stat_oserror(self, tmp_path):
        """OSError on stat during reload check should not crash."""
        policy = tmp_path / "policy.yml"
        policy.write_text("allowed:\n  - good.com\n")
        enforcer = Enforcer()
        with patch("enforcer.POLICY_PATH", policy), patch("enforcer.ctx"):
            enforcer._reload_policy()
            assert "good.com" in enforcer.allowlist
            # Force reload check by setting last_check far in the past.
            enforcer._last_check = time.monotonic() - 60
        # Now make stat fail during _maybe_reload's mtime check.
        with patch("enforcer.POLICY_PATH") as mock_path, patch("enforcer.ctx"):
            mock_path.exists.return_value = True
            mock_path.stat.side_effect = OSError("permission denied")
            # Should not raise — just log error and keep existing allowlist.
            enforcer._maybe_reload()
        assert "good.com" in enforcer.allowlist

    def test_request_skips_devbox_internal_endpoints(self, tmp_path):
        """/_devbox/ paths must bypass the enforcer for cmux integration."""
        enforcer = self._make_enforcer(tmp_path, domains=[])
        flow = MagicMock()
        flow.request.path = "/_devbox/notify"
        flow.request.pretty_host = "proxy"
        flow.response = None
        with patch("enforcer.ctx"):
            enforcer.request(flow)
        # Should NOT be blocked — notifier addon handles these.
        assert flow.response is None

    def test_maybe_reload_detects_file_change(self, tmp_path):
        policy = tmp_path / "policy.yml"
        policy.write_text("allowed:\n  - old.com\n")
        enforcer = Enforcer()
        with patch("enforcer.POLICY_PATH", policy), patch("enforcer.ctx"):
            enforcer._reload_policy()
            assert "old.com" in enforcer.allowlist

            # Simulate time passing and file change.
            enforcer._last_check = time.monotonic() - 60
            policy.write_text("allowed:\n  - new.com\n")
            enforcer._maybe_reload()
            assert "new.com" in enforcer.allowlist
            assert "old.com" not in enforcer.allowlist
