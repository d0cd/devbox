"""
mitmproxy addon: API request logger.

Logs all proxied HTTP requests and responses to a SQLite database for
observability and debugging. Derived from
nezhar/claude-container (MIT).
"""

import os
import sqlite3
import time
from pathlib import Path

from mitmproxy import ctx, http

DB_PATH = Path("/data/api.db")
# Truncate request/response bodies larger than this to save space.
MAX_BODY_SIZE = 65536
TRUNCATION_MARKER = "\n... [TRUNCATED by devbox logger at 64KB] ..."

# Schema version — increment when changing the schema and add a migration.
SCHEMA_VERSION = 1

# Prune rows older than this many days (0 = no pruning).
MAX_LOG_AGE_DAYS = int(os.environ.get("DEVBOX_LOG_MAX_AGE_DAYS", "90"))
# Maximum number of rows to retain (0 = no limit).
MAX_LOG_ROWS = int(os.environ.get("DEVBOX_LOG_MAX_ROWS", "100000"))

SCHEMA_V1 = """
CREATE TABLE IF NOT EXISTS requests (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
    method TEXT NOT NULL,
    url TEXT NOT NULL,
    host TEXT NOT NULL,
    status INTEGER,
    request_content_type TEXT,
    request_body TEXT,
    response_content_type TEXT,
    response_body TEXT,
    duration_ms INTEGER
);

CREATE INDEX IF NOT EXISTS idx_requests_timestamp ON requests(timestamp);
CREATE INDEX IF NOT EXISTS idx_requests_host ON requests(host);
CREATE INDEX IF NOT EXISTS idx_requests_status ON requests(status);
"""


def _init_schema(db: sqlite3.Connection) -> None:
    """Create the schema if needed and stamp the version."""
    try:
        row = db.execute("PRAGMA user_version").fetchone()
        current = int(row[0]) if row else 0
    except sqlite3.Error:
        current = 0
    if current >= SCHEMA_VERSION:
        return
    db.executescript(SCHEMA_V1)
    db.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
    db.commit()


def _truncate(body: bytes | None, max_size: int = MAX_BODY_SIZE) -> str | None:
    """Decode and optionally truncate a body for storage."""
    if body is None or len(body) == 0:
        return None

    text = body.decode("utf-8", errors="replace")

    if len(text) > max_size:
        return text[:max_size] + TRUNCATION_MARKER

    return text


def _prune(db: sqlite3.Connection) -> int:
    """Delete old rows beyond retention limits. Returns rows deleted."""
    deleted = 0
    if MAX_LOG_AGE_DAYS > 0:
        cursor = db.execute(
            "DELETE FROM requests WHERE timestamp < strftime('%Y-%m-%dT%H:%M:%f', 'now', ?)",
            (f"-{MAX_LOG_AGE_DAYS} days",),
        )
        deleted += cursor.rowcount
    if MAX_LOG_ROWS > 0:
        cursor = db.execute(
            "DELETE FROM requests WHERE id NOT IN (SELECT id FROM requests ORDER BY id DESC LIMIT ?)",
            (MAX_LOG_ROWS,),
        )
        deleted += cursor.rowcount
    if deleted > 0:
        db.commit()
    return deleted


class Logger:
    """mitmproxy addon that logs all requests to SQLite."""

    def __init__(self) -> None:
        self.db: sqlite3.Connection | None = None
        self._insert_count: int = 0

    def load(self, loader: object) -> None:
        """Initialize the SQLite database and schema."""
        DB_PATH.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(str(DB_PATH), timeout=5.0)
        # WAL mode reduces write contention with concurrent readers.
        self.db.execute("PRAGMA journal_mode=WAL")
        # Limit WAL file size to prevent unbounded growth.
        self.db.execute("PRAGMA journal_size_limit=67108864")
        # Incremental auto-vacuum reclaims space from deleted rows.
        self.db.execute("PRAGMA auto_vacuum=INCREMENTAL")
        _init_schema(self.db)
        # Prune old rows on startup.
        pruned = _prune(self.db)
        if pruned > 0:
            ctx.log.info(f"Pruned {pruned} old log rows")
        ctx.log.info(
            f"Logger initialized, writing to {DB_PATH} (schema v{SCHEMA_VERSION})"
        )

    def request(self, flow: http.HTTPFlow) -> None:
        """Record request start time for duration calculation."""
        flow.metadata["devbox_start_time"] = time.monotonic()

    def response(self, flow: http.HTTPFlow) -> None:
        """Log the completed request/response pair to SQLite."""
        if self.db is None:
            return

        start = flow.metadata.get("devbox_start_time")
        duration_ms = None
        if start is not None:
            duration_ms = int((time.monotonic() - start) * 1000)

        try:
            self.db.execute(
                """
                INSERT INTO requests
                    (method, url, host, status,
                     request_content_type, request_body,
                     response_content_type, response_body,
                     duration_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    flow.request.method,
                    flow.request.pretty_url,
                    flow.request.pretty_host,
                    flow.response.status_code if flow.response else None,
                    flow.request.headers.get("content-type"),
                    _truncate(flow.request.get_content()),
                    (
                        flow.response.headers.get("content-type")
                        if flow.response
                        else None
                    ),
                    _truncate(flow.response.get_content() if flow.response else None),
                    duration_ms,
                ),
            )
            self.db.commit()
            self._insert_count += 1
            # Periodic pruning to prevent unbounded growth.
            if self._insert_count % 1000 == 0:
                pruned = _prune(self.db)
                if pruned > 0:
                    ctx.log.info(f"Pruned {pruned} old log rows")
        except (sqlite3.Error, UnicodeDecodeError) as e:
            ctx.log.error(f"Failed to log request: {e}")

    def done(self) -> None:
        """Close the database on shutdown."""
        if self.db is not None:
            self.db.close()


addons = [Logger()]
