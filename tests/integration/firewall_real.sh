#!/usr/bin/env bash
# Real firewall integration test — runs inside the agent container.
#
# Usage (from CI or host):
#   docker run --rm --cap-add NET_ADMIN \
#     -v "$PWD/lib:/usr/local/lib/devbox:ro" \
#     -v "$PWD/tests:/tests:ro" \
#     devbox-agent:latest bash /tests/integration/firewall_real.sh
#
# Requires: iptables, curl, NET_ADMIN capability.
set -euo pipefail

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Real Firewall Integration Test ==="

# Set bridge subnet for firewall_init.
export DEVBOX_BRIDGE_SUBNET="${DEVBOX_BRIDGE_SUBNET:-172.17.0.0/16}"

# Source and run firewall init.
echo "[test] Initializing firewall..."
source /usr/local/lib/devbox/firewall.sh
firewall_init

echo ""
echo "[test] Verifying iptables rules..."

# Parse iptables output.
RULES="$(iptables -L OUTPUT -n -v)"
echo "$RULES"
echo ""

# Test 1: OUTPUT policy is DROP.
if echo "$RULES" | head -1 | grep -q "policy DROP"; then
    pass "OUTPUT policy is DROP"
else
    fail "OUTPUT policy is not DROP"
fi

# Test 2: Loopback rule exists (match ACCEPT on lo interface — column format varies).
if echo "$RULES" | grep "ACCEPT" | grep -q "lo"; then
    pass "Loopback rule exists"
else
    fail "Loopback rule missing"
fi

# Test 3: ESTABLISHED,RELATED rule exists.
if echo "$RULES" | grep -q "ESTABLISHED"; then
    pass "Established/related rule exists"
else
    fail "Established/related rule missing"
fi

# Test 4: Proxy port rule exists.
if echo "$RULES" | grep -q "dpt:8080"; then
    pass "Proxy port (8080) rule exists"
else
    fail "Proxy port (8080) rule missing"
fi

# Test 5: DNS rules exist.
if echo "$RULES" | grep -q "127.0.0.11.*dpt:53"; then
    pass "DNS resolver rules exist"
else
    fail "DNS resolver rules missing"
fi

# Test 6: Direct outbound is blocked.
echo ""
echo "[test] Verifying direct outbound is blocked..."
if curl -m 2 http://1.1.1.1 2>/dev/null; then
    fail "Direct outbound to 1.1.1.1 should be blocked"
else
    pass "Direct outbound to 1.1.1.1 is blocked"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
