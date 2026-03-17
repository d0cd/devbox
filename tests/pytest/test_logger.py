"""Tests for proxy/logger.py."""

import sqlite3
import time
from pathlib import Path
from unittest.mock import MagicMock, patch

from logger import Logger, _truncate, _prune, MAX_BODY_SIZE, TRUNCATION_MARKER


class TestTruncate:
    """Tests for _truncate()."""

    def test_none_returns_none(self):
        assert _truncate(None) is None

    def test_empty_returns_none(self):
        assert _truncate(b"") is None

    def test_small_body_unchanged(self):
        assert _truncate(b"hello world") == "hello world"

    def test_large_body_truncated(self):
        body = b"x" * (MAX_BODY_SIZE + 100)
        result = _truncate(body)
        assert result is not None
        assert result.endswith(TRUNCATION_MARKER)
        assert len(result) == MAX_BODY_SIZE + len(TRUNCATION_MARKER)

    def test_exact_max_not_truncated(self):
        body = b"x" * MAX_BODY_SIZE
        result = _truncate(body)
        assert result is not None
        assert TRUNCATION_MARKER not in result

    def test_binary_body_described(self):
        body = b"\x00\x01\x02\x03"
        result = _truncate(body)
        assert result is not None
        # Should decode (with replacement chars), not crash.
        assert isinstance(result, str)

    def test_custom_max_size(self):
        body = b"hello world"
        result = _truncate(body, max_size=5)
        assert result is not None
        assert result.startswith("hello")
        assert TRUNCATION_MARKER in result


class TestSchema:
    """Tests for database schema."""

    def test_requests_table_exists(self, temp_db):
        cursor = temp_db.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='requests'"
        )
        assert cursor.fetchone() is not None

    def test_insert_and_query(self, temp_db):
        temp_db.execute(
            """INSERT INTO requests (method, url, host, status, duration_ms)
               VALUES ('GET', 'https://example.com/', 'example.com', 200, 42)"""
        )
        temp_db.commit()
        row = temp_db.execute("SELECT * FROM requests").fetchone()
        assert row is not None

    def test_indexes_exist(self, temp_db):
        cursor = temp_db.execute(
            "SELECT name FROM sqlite_master WHERE type='index'"
        )
        indexes = {row[0] for row in cursor.fetchall()}
        assert "idx_requests_timestamp" in indexes
        assert "idx_requests_host" in indexes
        assert "idx_requests_status" in indexes


class TestLoggerClass:
    """Integration tests for the Logger mitmproxy addon."""

    def _make_logger(self, tmp_path):
        """Create a Logger with a temp database."""
        db_path = tmp_path / "test.db"
        logger_inst = Logger()
        with patch("logger.DB_PATH", db_path), \
             patch("logger.ctx"):
            logger_inst.load(None)
        return logger_inst, db_path

    def _make_flow(self, host="api.anthropic.com", method="POST",
                   status=200, req_body=b'{"model":"test"}',
                   resp_body=b'{"ok":true}'):
        flow = MagicMock()
        flow.request.method = method
        flow.request.pretty_url = f"https://{host}/v1/messages"
        flow.request.pretty_host = host
        flow.request.headers = {"content-type": "application/json"}
        flow.request.get_content.return_value = req_body
        flow.response = MagicMock()
        flow.response.status_code = status
        flow.response.headers = {"content-type": "application/json"}
        flow.response.get_content.return_value = resp_body
        flow.metadata = {}
        return flow

    def test_load_creates_schema(self, tmp_path):
        logger_inst, db_path = self._make_logger(tmp_path)
        assert db_path.exists()
        db = sqlite3.connect(str(db_path))
        tables = db.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()
        assert ("requests",) in tables
        db.close()
        logger_inst.done()

    def test_request_sets_start_time(self, tmp_path):
        logger_inst, _ = self._make_logger(tmp_path)
        flow = self._make_flow()
        logger_inst.request(flow)
        assert "devbox_start_time" in flow.metadata
        logger_inst.done()

    def test_response_logs_to_db(self, tmp_path):
        logger_inst, db_path = self._make_logger(tmp_path)
        flow = self._make_flow()
        logger_inst.request(flow)
        with patch("logger.ctx"):
            logger_inst.response(flow)
        db = sqlite3.connect(str(db_path))
        rows = db.execute("SELECT * FROM requests").fetchall()
        assert len(rows) == 1
        db.close()
        logger_inst.done()

    def test_response_calculates_duration(self, tmp_path):
        logger_inst, db_path = self._make_logger(tmp_path)
        flow = self._make_flow()
        flow.metadata["devbox_start_time"] = time.monotonic() - 0.1
        with patch("logger.ctx"):
            logger_inst.response(flow)
        db = sqlite3.connect(str(db_path))
        row = db.execute("SELECT duration_ms FROM requests").fetchone()
        assert row[0] is not None
        assert row[0] >= 100  # At least 100ms.
        db.close()
        logger_inst.done()

    def test_response_with_no_db_is_noop(self, tmp_path):
        logger_inst = Logger()  # db is None, load() not called.
        flow = self._make_flow()
        # Should not raise.
        logger_inst.response(flow)

    def test_response_with_none_response(self, tmp_path):
        logger_inst, db_path = self._make_logger(tmp_path)
        flow = self._make_flow()
        flow.response = None
        logger_inst.request(flow)
        with patch("logger.ctx"):
            logger_inst.response(flow)
        db = sqlite3.connect(str(db_path))
        row = db.execute("SELECT status FROM requests").fetchone()
        assert row[0] is None  # No response status.
        db.close()
        logger_inst.done()

    def test_done_closes_db(self, tmp_path):
        logger_inst, _ = self._make_logger(tmp_path)
        assert logger_inst.db is not None
        logger_inst.done()
        # After done(), db should be closed. Attempting to use it should fail.
        # (SQLite closed connections raise ProgrammingError on use)

    def test_done_with_no_db_is_noop(self):
        logger_inst = Logger()
        # Should not raise.
        logger_inst.done()


class TestPrune:
    """Tests for _prune() retention logic."""

    def _insert_rows(self, db, count):
        for i in range(count):
            db.execute(
                "INSERT INTO requests (method, url, host, status) VALUES (?, ?, ?, ?)",
                ("GET", f"https://example.com/{i}", "example.com", 200),
            )
        db.commit()

    def test_prune_by_max_rows(self, temp_db):
        self._insert_rows(temp_db, 10)
        with patch("logger.MAX_LOG_ROWS", 5), patch("logger.MAX_LOG_AGE_DAYS", 0):
            deleted = _prune(temp_db)
        assert deleted == 5
        remaining = temp_db.execute("SELECT COUNT(*) FROM requests").fetchone()[0]
        assert remaining == 5

    def test_prune_no_op_when_under_limit(self, temp_db):
        self._insert_rows(temp_db, 3)
        with patch("logger.MAX_LOG_ROWS", 10), patch("logger.MAX_LOG_AGE_DAYS", 0):
            deleted = _prune(temp_db)
        assert deleted == 0

    def test_prune_disabled_when_zero(self, temp_db):
        self._insert_rows(temp_db, 10)
        with patch("logger.MAX_LOG_ROWS", 0), patch("logger.MAX_LOG_AGE_DAYS", 0):
            deleted = _prune(temp_db)
        assert deleted == 0
        remaining = temp_db.execute("SELECT COUNT(*) FROM requests").fetchone()[0]
        assert remaining == 10
