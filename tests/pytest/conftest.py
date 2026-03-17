"""Shared fixtures for devbox proxy tests."""

import sqlite3
import sys
import tempfile
from pathlib import Path
from unittest.mock import MagicMock

import pytest

# Add proxy directory to path so we can import modules.
PROXY_DIR = Path(__file__).resolve().parent.parent.parent / "proxy"
sys.path.insert(0, str(PROXY_DIR))


@pytest.fixture
def temp_db():
    """Create a temporary SQLite database with the logger schema."""
    from logger import SCHEMA_V1 as SCHEMA

    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
        db_path = f.name
    db = sqlite3.connect(db_path)
    db.executescript(SCHEMA)
    db.commit()
    yield db
    db.close()
    Path(db_path).unlink(missing_ok=True)


@pytest.fixture
def mock_flow():
    """Create a mock mitmproxy HTTP flow."""
    flow = MagicMock()
    flow.request.method = "POST"
    flow.request.pretty_url = "https://api.anthropic.com/v1/messages"
    flow.request.pretty_host = "api.anthropic.com"
    flow.request.headers = {"content-type": "application/json"}
    flow.request.get_content.return_value = b'{"model": "claude-sonnet-4-5"}'
    flow.response = MagicMock()
    flow.response.status_code = 200
    flow.response.headers = {"content-type": "application/json"}
    flow.response.get_content.return_value = (
        b'{"usage": {"input_tokens": 100, "output_tokens": 50}}'
    )
    flow.metadata = {}
    return flow


@pytest.fixture
def temp_policy(tmp_path):
    """Create a temporary policy file."""
    policy = tmp_path / "policy.yml"
    policy.write_text(
        'version: 1\nallowed:\n  - api.anthropic.com\n  - "*.openai.com"\n'
    )
    return policy
