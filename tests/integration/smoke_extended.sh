#!/usr/bin/env bash
# Extended smoke test for devbox proxy enforcement and observability.
#
# Usage (from CI or host):
#   ./tests/integration/smoke_extended.sh
#
# Expects: Docker available, proxy and agent images built as *:latest.
set -euo pipefail

PASS=0
FAIL=0
CONTAINER_NAME="devbox-smoke-test-$$"

pass() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
}
fail() {
    echo "  FAIL: $1"
    FAIL=$((FAIL + 1))
}

cleanup() {
    echo "[smoke] Cleaning up..."
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Extended Smoke Test ==="

# Start proxy with default policy.
echo "[smoke] Starting proxy container..."
docker run -d --name "$CONTAINER_NAME" \
    -v "$PWD/templates/policy.yml:/proxy/policy.yml:ro" \
    -p 18080:8080 \
    devbox-proxy:latest

# Wait for proxy to be ready.
PROXY_READY=false
for i in $(seq 1 20); do
    if python3 -c "import socket; socket.create_connection(('localhost', 18080), timeout=1)" 2>/dev/null; then
        PROXY_READY=true
        break
    fi
    sleep 1
done

if [ "$PROXY_READY" != "true" ]; then
    echo "FATAL: Proxy did not become ready after 20s"
    docker logs "$CONTAINER_NAME"
    exit 1
fi
echo "[smoke] Proxy is ready."

# Test 1: Allowed domain should not get 403.
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -x http://localhost:18080 http://api.anthropic.com/ || true)
if [ "$STATUS" != "403" ]; then
    pass "Allowed domain (api.anthropic.com) not blocked (status: $STATUS)"
else
    fail "Allowed domain got 403"
fi

# Test 2: Blocked domain should get 403.
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -x http://localhost:18080 http://evil.com/ || true)
if [ "$STATUS" = "403" ]; then
    pass "Blocked domain (evil.com) returns 403"
else
    fail "Blocked domain expected 403, got $STATUS"
fi

# Test 3: Wildcard domain enforcement.
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -x http://localhost:18080 http://raw.githubusercontent.com/ || true)
if [ "$STATUS" != "403" ]; then
    pass "Wildcard domain (*.githubusercontent.com) not blocked (status: $STATUS)"
else
    fail "Wildcard domain (*.githubusercontent.com) got 403"
fi

# Test 4: Another blocked domain.
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -x http://localhost:18080 http://malware.example.org/ || true)
if [ "$STATUS" = "403" ]; then
    pass "Blocked domain (malware.example.org) returns 403"
else
    fail "Blocked domain expected 403, got $STATUS"
fi

# Test 5: SQLite log DB populated after proxied requests.
echo "[smoke] Checking API log..."
sleep 2 # Give logger time to write.
LOG_COUNT=$(docker exec "$CONTAINER_NAME" python3 -c "
import sqlite3, os
db_path = '/data/api.db'
if not os.path.exists(db_path):
    print(0)
else:
    db = sqlite3.connect(db_path)
    count = db.execute('SELECT COUNT(*) FROM requests').fetchone()[0]
    print(count)
    db.close()
" 2>/dev/null || echo "0")
if [ "$LOG_COUNT" -gt 0 ]; then
    pass "API log has $LOG_COUNT entries after proxied requests"
else
    fail "API log is empty (expected entries from proxy test requests)"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
