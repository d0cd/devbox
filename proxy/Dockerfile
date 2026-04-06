# Proxy sidecar: mitmproxy with domain enforcement and request logging.
FROM python:3.12-slim@sha256:ccc7089399c8bb65dd1fb3ed6d55efa538a3f5e7fca3f5988ac3b5b87e593bf0

ARG DEVBOX_VERSION=0.3.0
LABEL org.opencontainers.image.title="devbox-proxy" \
      org.opencontainers.image.version="${DEVBOX_VERSION}"

COPY --from=ghcr.io/astral-sh/uv:0.10.10 /uv /usr/local/bin/uv
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install --system mitmproxy==12.2.1 pyyaml==6.0.3

# Create non-root user for running the proxy.
RUN groupadd -g 1000 devbox && useradd -u 1000 -g devbox -d /home/devbox -s /bin/bash devbox

COPY enforcer.py injector.py notifier.py logger.py /proxy/

# /data is where the SQLite API log is written.
# /ca is the proxy-only volume for CA keypair persistence across restarts.
# /ca-cert is the shared volume for the public CA cert (agent reads this).
# /home/devbox/.mitmproxy stores the active CA keypair for mitmproxy.
# Seed volume dirs with a file so Docker copies ownership into named volumes.
# (Docker only initializes volume ownership when there are files to copy.)
RUN mkdir -p /data /ca /ca-cert /home/devbox/.mitmproxy \
    && touch /ca/.keep /ca-cert/.keep /data/.keep \
    && chown -R devbox:devbox /data /ca /ca-cert /home/devbox/.mitmproxy /proxy

EXPOSE 8080

# Run mitmproxy with enforcer and logger addons.
COPY entrypoint.sh /proxy/entrypoint.sh
RUN chmod +x /proxy/entrypoint.sh

USER devbox
ENTRYPOINT ["/proxy/entrypoint.sh"]
