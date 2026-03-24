#!/usr/bin/env bash
# Agent container entrypoint.
#
# Two-phase startup:
#   Phase 1 (root): firewall + CA certificate — requires NET_ADMIN and system paths.
#   Phase 2 (devbox): user-setup.sh — git identity, config overlay, hold open.
#
# This structure keeps cap_drop: ALL + cap_add: NET_ADMIN only.
# No DAC_OVERRIDE, CHOWN, or FOWNER needed.
set -euo pipefail

# =========================================================================
# Phase 1: Root — firewall and CA certificate (requires elevated privileges)
# =========================================================================

# --- Detect bridge subnet ---
if [ -z "${DEVBOX_BRIDGE_SUBNET:-}" ]; then
    DEVBOX_BRIDGE_SUBNET="$(ip route | awk '!/default/ && /dev/ && /src/ {print $1; exit}')" || true
    if [ -z "$DEVBOX_BRIDGE_SUBNET" ]; then
        DEVBOX_BRIDGE_SUBNET="$(ip route | awk '/default/ {print $3}' | head -1 | sed 's/\.[0-9]*$/\.0\/16/')" || true
    fi
    if [ -z "$DEVBOX_BRIDGE_SUBNET" ]; then
        DEVBOX_BRIDGE_SUBNET="172.17.0.0/16"
        echo "[entrypoint] Could not detect bridge subnet, using fallback: $DEVBOX_BRIDGE_SUBNET"
    else
        echo "[entrypoint] Detected bridge subnet: $DEVBOX_BRIDGE_SUBNET"
    fi
    export DEVBOX_BRIDGE_SUBNET
else
    echo "[entrypoint] Using configured bridge subnet: $DEVBOX_BRIDGE_SUBNET"
fi

# Source firewall module (defines CIDR_PATTERN and firewall_init).
if [ ! -f /usr/local/lib/devbox/firewall.sh ]; then
    echo "[entrypoint] FATAL: firewall.sh not found at /usr/local/lib/devbox/firewall.sh"
    exit 1
fi
source /usr/local/lib/devbox/firewall.sh

if [[ ! "$DEVBOX_BRIDGE_SUBNET" =~ $CIDR_PATTERN ]]; then
    echo "[entrypoint] FATAL: Invalid bridge subnet: '$DEVBOX_BRIDGE_SUBNET'"
    exit 1
fi

# Initialize iptables firewall — mandatory for container safety.
if command -v iptables &>/dev/null; then
    if ! firewall_init; then
        echo "[entrypoint] Firewall init failed, retrying in 2s..."
        sleep 2
        if ! firewall_init; then
            echo "[entrypoint] FATAL: Firewall initialization failed. Refusing to start."
            exit 1
        fi
    fi
else
    echo "[entrypoint] FATAL: iptables not available. Cannot enforce network policy."
    exit 1
fi

# --- Proxy CA Certificate ---
# The proxy CA cert is on a shared volume mounted read-only at /run/proxy-ca.
# Copy it into the system CA directory so update-ca-certificates can process it.
CA_STAGING="/run/proxy-ca/mitmproxy-ca-cert.pem"
CA_CERT="/usr/local/share/ca-certificates/mitmproxy-ca.crt"
CA_TIMEOUT=60
CA_ELAPSED=0
while [ ! -f "$CA_STAGING" ] && [ "$CA_ELAPSED" -lt "$CA_TIMEOUT" ]; do
    if [ "$CA_ELAPSED" -eq 0 ]; then
        echo "[entrypoint] Waiting for proxy CA certificate..."
    elif [ "$((CA_ELAPSED % 5))" -eq 0 ]; then
        echo "[entrypoint] Still waiting for CA certificate... (${CA_ELAPSED}s/${CA_TIMEOUT}s)"
    fi
    sleep 1
    CA_ELAPSED=$((CA_ELAPSED + 1))
done
if [ ! -f "$CA_STAGING" ]; then
    echo "[entrypoint] FATAL: Proxy CA cert not found at $CA_STAGING after ${CA_TIMEOUT}s"
    exit 1
fi
echo "[entrypoint] Installing proxy CA certificate..."
cp "$CA_STAGING" "$CA_CERT"
if ! ca_output="$(update-ca-certificates --fresh 2>&1)"; then
    echo "[entrypoint] FATAL: update-ca-certificates failed"
    echo "$ca_output"
    exit 1
fi
# Append mitmproxy cert to the system bundle (update-ca-certificates symlinks
# local certs but doesn't always append them to the PEM bundle on Ubuntu).
cat "$CA_CERT" >> /etc/ssl/certs/ca-certificates.crt
[ -n "$ca_output" ] && echo "$ca_output" | tail -1

export NODE_EXTRA_CA_CERTS="$CA_CERT"
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

# =========================================================================
# Phase 2: Drop to unprivileged user — config overlay and hold container open
# =========================================================================
exec gosu devbox /usr/local/bin/user-setup.sh "$@"
