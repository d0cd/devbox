"""Tests for configuration file validity."""

import json
from pathlib import Path

import yaml

# Project root.
ROOT = Path(__file__).resolve().parent.parent.parent


class TestOpenCodeConfig:
    """Verify config/opencode/opencode.json is valid."""

    def test_is_valid_json(self):
        config = ROOT / "config" / "opencode" / "opencode.json"
        assert config.exists(), "opencode.json not found"
        data = json.loads(config.read_text())
        assert isinstance(data, dict)

    def test_has_required_keys(self):
        config = ROOT / "config" / "opencode" / "opencode.json"
        data = json.loads(config.read_text())
        # OpenCode config should have at minimum a provider or model config.
        assert any(
            key in data for key in ("provider", "providers", "model", "mcpServers")
        ), f"opencode.json missing expected keys, got: {list(data.keys())}"


class TestPolicyTemplate:
    """Verify templates/policy.yml is valid."""

    def test_is_valid_yaml(self):
        policy = ROOT / "templates" / "policy.yml"
        assert policy.exists(), "policy.yml not found"
        data = yaml.safe_load(policy.read_text())
        assert isinstance(data, dict)

    def test_has_version_and_allowed(self):
        policy = ROOT / "templates" / "policy.yml"
        data = yaml.safe_load(policy.read_text())
        assert "version" in data, "policy.yml missing 'version' key"
        assert "allowed" in data, "policy.yml missing 'allowed' key"
        assert isinstance(data["allowed"], list), "'allowed' should be a list"
        assert len(data["allowed"]) > 0, "'allowed' should not be empty"


class TestClinkSystemPrompts:
    """Verify all clink system prompt files are non-empty."""

    def test_all_prompts_non_empty(self):
        prompts_dir = ROOT / "config" / "opencode" / "pal" / "systemprompts" / "clink"
        if not prompts_dir.exists():
            # Try alternate path.
            prompts_dir = ROOT / "config" / "pal" / "systemprompts" / "clink"
        if not prompts_dir.exists():
            return  # Skip if clink prompts not yet created.
        prompt_files = list(prompts_dir.glob("*.md"))
        assert len(prompt_files) > 0, "No clink system prompt files found"
        for f in prompt_files:
            content = f.read_text().strip()
            assert len(content) > 0, f"Prompt file is empty: {f.name}"


class TestProfileScripts:
    """Verify profile scripts have consistent structure."""

    def test_all_profiles_have_shebang(self):
        profiles_dir = ROOT / "tooling" / "profiles"
        for f in profiles_dir.glob("*.sh"):
            first_line = f.read_text().split("\n")[0]
            assert first_line.startswith("#!/"), f"{f.name} missing shebang"

    def test_all_profiles_have_set_euo_pipefail(self):
        profiles_dir = ROOT / "tooling" / "profiles"
        for f in profiles_dir.glob("*.sh"):
            content = f.read_text()
            assert "set -euo pipefail" in content, f"{f.name} missing set -euo pipefail"
