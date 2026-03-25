# Proxy sidecar: mitmproxy with domain enforcement and request logging.
FROM python:3.14-slim@sha256:fb83750094b46fd6b8adaa80f66e2302ecbe45d513f6cece637a841e1025b4ca

ARG DEVBOX_VERSION=0.3.0
LABEL org.opencontainers.image.title="devbox-proxy" \
      org.opencontainers.image.version="${DEVBOX_VERSION}"

COPY --from=ghcr.io/astral-sh/uv:0.10.10 /uv /usr/local/bin/uv
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install --system mitmproxy==12.2.1 pyyaml==6.0.3

# Create non-root user for running the proxy.
RUN groupadd -g 1000 devbox && useradd -u 1000 -g devbox -d /home/devbox -s /bin/bash devbox

COPY enforcer.py injector.py logger.py /proxy/

# /data is where the SQLite API log is written.
# /ca is the shared volume for CA certs.
# /home/devbox/.mitmproxy stores the generated CA keypair.
# Seed volume dirs with a file so Docker copies ownership into named volumes.
# (Docker only initializes volume ownership when there are files to copy.)
RUN mkdir -p /data /ca /home/devbox/.mitmproxy \
    && touch /ca/.keep /data/.keep \
    && chown -R devbox:devbox /data /ca /home/devbox/.mitmproxy /proxy

EXPOSE 8080

# Run mitmproxy with enforcer and logger addons.
COPY entrypoint.sh /proxy/entrypoint.sh
RUN chmod +x /proxy/entrypoint.sh

USER devbox
ENTRYPOINT ["/proxy/entrypoint.sh"]
