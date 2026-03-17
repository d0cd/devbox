#!/usr/bin/env bash
# Proxy sidecar entrypoint: starts mitmproxy with enforcer and logger addons.
set -euo pipefail

# Generate CA certs on first run and export to shared volume.
# Use flock to serialize concurrent proxy starts on the same volume.
(
    flock -w 60 200 || {
        echo "[proxy] FATAL: Could not acquire CA lock"
        exit 1
    }
    if [ ! -f /ca/mitmproxy-ca-cert.pem ]; then
        echo "[proxy] Generating mitmproxy CA certificate (may take up to 30s)..."
        # Run mitmproxy briefly to generate the CA cert, then copy it out.
        mitmdump --set confdir=/home/devbox/.mitmproxy -q &
        MITM_PID=$!

        # Poll for the cert file instead of a fixed sleep.
        TIMEOUT=60
        ELAPSED=0
        while [ ! -f /home/devbox/.mitmproxy/mitmproxy-ca-cert.pem ] && [ "$ELAPSED" -lt "$TIMEOUT" ]; do
            sleep 1
            ELAPSED=$((ELAPSED + 1))
            if [ "$((ELAPSED % 10))" -eq 0 ]; then
                echo "[proxy] Still waiting for CA certificate generation... (${ELAPSED}s/${TIMEOUT}s)"
            fi
        done

        kill "$MITM_PID" 2>/dev/null || true
        wait "$MITM_PID" 2>/dev/null || true

        if [ ! -f /home/devbox/.mitmproxy/mitmproxy-ca-cert.pem ]; then
            echo "[proxy] FATAL: CA certificate was not generated within ${TIMEOUT}s"
            exit 1
        fi

        cp /home/devbox/.mitmproxy/mitmproxy-ca-cert.pem /ca/mitmproxy-ca-cert.pem
        echo "[proxy] CA certificate exported to /ca/mitmproxy-ca-cert.pem"
    fi
) 200>/ca/.ca-lock

# Validate addon files exist and have no syntax errors before starting anything.
for addon in /proxy/enforcer.py /proxy/logger.py; do
    if [ ! -f "$addon" ]; then
        echo "[proxy] FATAL: Addon not found: $addon"
        exit 1
    fi
    if ! compile_output=$(python3 -c "import py_compile; py_compile.compile('$addon', doraise=True)" 2>&1); then
        echo "[proxy] FATAL: Syntax error in addon: $addon"
        echo "$compile_output"
        exit 1
    fi
done

# Ensure the data directory exists. Schema is created by logger.py addon.
mkdir -p /data
touch /data/api.db

# Start mitmproxy with enforcer and logger addons.
echo "[proxy] Starting mitmproxy enforcer on port 8080..."
exec mitmdump \
    --set confdir=/home/devbox/.mitmproxy \
    -s /proxy/enforcer.py \
    -s /proxy/logger.py \
    --listen-port 8080 \
    --set block_global=false
