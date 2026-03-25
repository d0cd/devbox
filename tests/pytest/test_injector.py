"""Tests for proxy/injector.py."""

from unittest.mock import patch

from conftest import MutableHeaders, make_injector_flow

from injector import (
    Injector,
    _load_credentials,
)


class TestLoadCredentials:
    """Tests for _load_credentials()."""

    def test_no_env_vars_returns_empty(self):
        with patch.dict("os.environ", {}, clear=True):
            result = _load_credentials()
        assert result == {}

    def test_loads_anthropic_key(self):
        with patch.dict(
            "os.environ", {"DEVBOX_INJECT_ANTHROPIC": "sk-ant-test"}, clear=True
        ):
            result = _load_credentials()
        assert "api.anthropic.com" in result
        header, value = result["api.anthropic.com"]
        assert header == "x-api-key"
        assert value == "sk-ant-test"

    def test_loads_openai_key_with_bearer(self):
        with patch.dict(
            "os.environ", {"DEVBOX_INJECT_OPENAI": "sk-openai-test"}, clear=True
        ):
            result = _load_credentials()
        assert "api.openai.com" in result
        header, value = result["api.openai.com"]
        assert header == "authorization"
        assert value == "Bearer sk-openai-test"

    def test_loads_gemini_key(self):
        with patch.dict(
            "os.environ", {"DEVBOX_INJECT_GEMINI": "gemini-test"}, clear=True
        ):
            result = _load_credentials()
        assert "generativelanguage.googleapis.com" in result
        header, value = result["generativelanguage.googleapis.com"]
        assert header == "x-goog-api-key"
        assert value == "gemini-test"

    def test_loads_openrouter_key_with_bearer(self):
        with patch.dict(
            "os.environ", {"DEVBOX_INJECT_OPENROUTER": "sk-or-test"}, clear=True
        ):
            result = _load_credentials()
        assert "openrouter.ai" in result
        header, value = result["openrouter.ai"]
        assert header == "authorization"
        assert value == "Bearer sk-or-test"

    def test_loads_github_key_with_bearer(self):
        with patch.dict(
            "os.environ", {"DEVBOX_INJECT_GITHUB": "ghp_test"}, clear=True
        ):
            result = _load_credentials()
        assert "api.github.com" in result
        header, value = result["api.github.com"]
        assert header == "authorization"
        assert value == "Bearer ghp_test"

    def test_multiple_providers(self):
        env = {
            "DEVBOX_INJECT_ANTHROPIC": "sk-ant-test",
            "DEVBOX_INJECT_OPENAI": "sk-openai-test",
            "DEVBOX_INJECT_GITHUB": "ghp_test",
        }
        with patch.dict("os.environ", env, clear=True):
            result = _load_credentials()
        assert len(result) == 3
        assert "api.anthropic.com" in result
        assert "api.openai.com" in result
        assert "api.github.com" in result

    def test_empty_value_skipped(self):
        with patch.dict(
            "os.environ", {"DEVBOX_INJECT_ANTHROPIC": ""}, clear=True
        ):
            result = _load_credentials()
        assert result == {}

    def test_unknown_env_var_ignored(self):
        with patch.dict(
            "os.environ", {"DEVBOX_INJECT_UNKNOWN": "value"}, clear=True
        ):
            result = _load_credentials()
        assert result == {}


class TestInjectorNoOp:
    """Tests for injector when no credentials are configured."""

    def test_request_unchanged_when_no_credentials(self):
        injector = Injector()
        with patch.dict("os.environ", {}, clear=True), patch("injector.ctx"):
            injector.load(None)
        flow = make_injector_flow("api.anthropic.com", headers={"x-api-key": "phantom"})
        injector.request(flow)
        assert flow.request.headers["x-api-key"] == "phantom"


class TestInjectorStripAndInject:
    """Tests for the strip-then-inject pattern."""

    def _make_injector(self, env):
        injector = Injector()
        with patch.dict("os.environ", env, clear=True), patch("injector.ctx"):
            injector.load(None)
        return injector

    def test_strips_existing_and_injects_anthropic(self):
        injector = self._make_injector({"DEVBOX_INJECT_ANTHROPIC": "sk-ant-real"})
        flow = make_injector_flow(
            "api.anthropic.com", headers={"x-api-key": "sk-devbox-phantom"}
        )
        injector.request(flow)
        assert flow.request.headers["x-api-key"] == "sk-ant-real"

    def test_injects_when_no_existing_header(self):
        injector = self._make_injector({"DEVBOX_INJECT_ANTHROPIC": "sk-ant-real"})
        flow = make_injector_flow("api.anthropic.com")
        injector.request(flow)
        assert flow.request.headers["x-api-key"] == "sk-ant-real"

    def test_injects_bearer_for_openai(self):
        injector = self._make_injector({"DEVBOX_INJECT_OPENAI": "sk-openai-real"})
        flow = make_injector_flow(
            "api.openai.com", headers={"authorization": "Bearer phantom"}
        )
        injector.request(flow)
        assert flow.request.headers["authorization"] == "Bearer sk-openai-real"

    def test_injects_gemini(self):
        injector = self._make_injector({"DEVBOX_INJECT_GEMINI": "gemini-real"})
        flow = make_injector_flow("generativelanguage.googleapis.com")
        injector.request(flow)
        assert flow.request.headers["x-goog-api-key"] == "gemini-real"

    def test_injects_openrouter(self):
        injector = self._make_injector({"DEVBOX_INJECT_OPENROUTER": "sk-or-real"})
        flow = make_injector_flow("openrouter.ai")
        injector.request(flow)
        assert flow.request.headers["authorization"] == "Bearer sk-or-real"

    def test_injects_github(self):
        injector = self._make_injector({"DEVBOX_INJECT_GITHUB": "ghp_real"})
        flow = make_injector_flow("api.github.com")
        injector.request(flow)
        assert flow.request.headers["authorization"] == "Bearer ghp_real"

    def test_sets_metadata_flag(self):
        injector = self._make_injector({"DEVBOX_INJECT_ANTHROPIC": "sk-ant-real"})
        flow = make_injector_flow("api.anthropic.com")
        injector.request(flow)
        assert flow.metadata.get("devbox_injected") is True


class TestInjectorSkipBehavior:
    """Tests for cases where the injector should not touch the request."""

    def _make_injector(self, env):
        injector = Injector()
        with patch.dict("os.environ", env, clear=True), patch("injector.ctx"):
            injector.load(None)
        return injector

    def test_skips_blocked_flow(self):
        injector = self._make_injector({"DEVBOX_INJECT_ANTHROPIC": "sk-ant-real"})
        flow = make_injector_flow(
            "api.anthropic.com", headers={"x-api-key": "phantom"}, blocked=True
        )
        injector.request(flow)
        # Header should be unchanged — injector skipped this flow.
        assert flow.request.headers["x-api-key"] == "phantom"

    def test_skips_non_provider_domain(self):
        injector = self._make_injector({"DEVBOX_INJECT_ANTHROPIC": "sk-ant-real"})
        flow = make_injector_flow(
            "github.com", headers={"authorization": "Bearer ghp_token"}
        )
        injector.request(flow)
        # github.com is not api.github.com — should not be touched.
        assert flow.request.headers["authorization"] == "Bearer ghp_token"

    def test_skips_unknown_domain(self):
        injector = self._make_injector({"DEVBOX_INJECT_ANTHROPIC": "sk-ant-real"})
        flow = make_injector_flow("example.com", headers={"x-custom": "value"})
        injector.request(flow)
        assert flow.request.headers["x-custom"] == "value"
        assert "x-api-key" not in flow.request.headers
