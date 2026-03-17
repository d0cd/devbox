#!/usr/bin/env bats
# Tests for cmd_logs (lib/commands.sh)

load test_helper

setup() {
    command -v sqlite3 &>/dev/null || skip "sqlite3 not available"
    setup_libs
    stub_devbox_env
    CIDR_PATTERN='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$'
    export CIDR_PATTERN
    source "${DEVBOX_ROOT}/lib/commands.sh"

    # Create a test SQLite database with sample data.
    local hash
    hash="$(project_hash "$(pwd)")"
    mkdir -p "${DEVBOX_DATA}/${hash}/logs"
    TEST_DB="${DEVBOX_DATA}/${hash}/logs/api.db"

    sqlite3 "$TEST_DB" <<'SQL'
CREATE TABLE requests (
    id INTEGER PRIMARY KEY,
    timestamp TEXT,
    method TEXT,
    host TEXT,
    url TEXT,
    status INTEGER,
    duration_ms INTEGER,
    request_body TEXT,
    response_body TEXT
);
INSERT INTO requests VALUES (1, '2026-03-15 10:00:00', 'POST', 'api.anthropic.com', '/v1/messages', 200, 1200, '', '');
INSERT INTO requests VALUES (2, '2026-03-15 10:05:00', 'POST', 'api.openai.com', '/v1/chat', 500, 3000, '', '');
INSERT INTO requests VALUES (3, '2026-03-15 11:00:00', 'GET', 'evil.com', '/', 403, 5, '', '');
INSERT INTO requests VALUES (4, '2026-03-15 12:00:00', 'POST', 'api.anthropic.com', '/v1/messages', 200, 8000, '', '');
INSERT INTO requests VALUES (5, '2026-03-16 09:00:00', 'POST', 'api.anthropic.com', '/v1/messages', 200, 500, '', '');
SQL
}

teardown() {
    rm -rf "$DEVBOX_DATA" "$DEVBOX_CONFIG" 2>/dev/null || true
}

@test "logs shows recent requests" {
    run cmd_logs
    [ "$status" -eq 0 ]
    [[ "$output" == *"api.anthropic.com"* ]]
}

@test "logs --errors shows only 4xx/5xx" {
    run cmd_logs --errors
    [ "$status" -eq 0 ]
    [[ "$output" == *"api.openai.com"* ]]
    [[ "$output" == *"500"* ]]
}

@test "logs --blocked shows only 403" {
    run cmd_logs --blocked
    [ "$status" -eq 0 ]
    [[ "$output" == *"evil.com"* ]]
}

@test "logs --slow shows requests over 5s" {
    run cmd_logs --slow
    [ "$status" -eq 0 ]
    [[ "$output" == *"8000"* ]]
}

@test "logs --hosts groups by host" {
    run cmd_logs --hosts
    [ "$status" -eq 0 ]
    [[ "$output" == *"api.anthropic.com"* ]]
    [[ "$output" == *"evil.com"* ]]
}

@test "logs --since filters by start time" {
    run cmd_logs --since "2026-03-16"
    [ "$status" -eq 0 ]
    # March 16 entry should be present.
    [[ "$output" == *"api.anthropic.com"* ]]
    # March 15 entries should be excluded (evil.com and openai.com are only on March 15).
    [[ "$output" != *"evil.com"* ]]
    [[ "$output" != *"api.openai.com"* ]]
}

@test "logs --until filters by end time" {
    run cmd_logs --until "2026-03-15 10:30:00"
    [ "$status" -eq 0 ]
    [[ "$output" == *"api.anthropic.com"* ]]
    [[ "$output" == *"api.openai.com"* ]]
    # Should not include the later entries
    [[ "$output" != *"evil.com"* ]]
}

@test "logs --since and --until combined" {
    run cmd_logs --since "2026-03-15 10:00:00" --until "2026-03-15 10:30:00"
    [ "$status" -eq 0 ]
    [[ "$output" == *"api.anthropic.com"* ]]
    [[ "$output" == *"api.openai.com"* ]]
    [[ "$output" != *"evil.com"* ]]
}

@test "logs --since with --errors combines filters" {
    run cmd_logs --since "2026-03-15" --errors
    [ "$status" -eq 0 ]
    [[ "$output" == *"500"* ]]
}

@test "logs --since with quotes does not inject SQL" {
    # Single quotes in timestamp should be escaped, not break the query.
    run cmd_logs --since "2026-03-15' OR '1'='1"
    # Should succeed (return 0 results) — not crash or return all rows.
    [ "$status" -eq 0 ]
    # Should NOT match any rows (the injected string is not a valid timestamp).
    [[ "$output" != *"evil.com"* ]]
}
