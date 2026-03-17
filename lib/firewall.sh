#!/usr/bin/env bash
# Initialize iptables firewall inside the agent container.
#
# Blocks all direct outbound traffic except to the Docker bridge network
# where the proxy sidecar runs. This is the second layer of network
# enforcement — even processes that ignore HTTP_PROXY env vars cannot
# reach the internet directly.
#
# Derived from mattolson/agent-sandbox (MIT).
set -euo pipefail

CIDR_PATTERN='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$'

firewall_init() {
    echo "[firewall] Initializing iptables rules..."

    # Flush any existing rules (intentional — container should have none).
    iptables -F OUTPUT

    # Default policy: drop all outbound.
    iptables -P OUTPUT DROP

    # Allow loopback (localhost communication).
    iptables -A OUTPUT -o lo -j ACCEPT

    # Allow established and related connections (responses to inbound).
    iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # Allow traffic to Docker bridge network where the proxy sidecar lives.
    # DEVBOX_BRIDGE_SUBNET is set by the entrypoint after detecting the
    # actual network. Falls back to Docker's default range.
    local bridge_subnet="${DEVBOX_BRIDGE_SUBNET:-172.17.0.0/16}"
    if [[ ! "$bridge_subnet" =~ $CIDR_PATTERN ]]; then
        echo "[firewall] FATAL: Invalid bridge subnet CIDR: '$bridge_subnet'"
        return 1
    fi
    # Allow only the proxy port (8080) on the bridge.
    iptables -A OUTPUT -d "$bridge_subnet" -p tcp --dport 8080 -j ACCEPT

    # Allow DNS only to Docker's embedded DNS resolver (127.0.0.11).
    # Restricting to this address prevents DNS tunneling to external servers.
    iptables -A OUTPUT -d 127.0.0.11 -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -d 127.0.0.11 -p tcp --dport 53 -j ACCEPT

    echo "[firewall] IPv4 rules applied."

    # Block IPv6 if ip6tables is available (prevents bypass via IPv6 if enabled).
    # All-or-nothing: if flush or policy DROP fails, skip all IPv6 rules to avoid
    # inconsistent state (flushed chain with ACCEPT policy).
    if command -v ip6tables &>/dev/null; then
        if ip6tables -F OUTPUT 2>/dev/null && ip6tables -P OUTPUT DROP 2>/dev/null; then
            ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
            ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
            echo "[firewall] IPv6 rules applied (all outbound dropped)."
        else
            echo "[firewall] WARNING: IPv6 firewall rules failed — IPv6 traffic may bypass the firewall."
        fi
    fi

    echo "[firewall] All direct outbound blocked except Docker bridge."

    # Verify a known rule exists — confirms firewall setup completed.
    if ! iptables -C OUTPUT -d 127.0.0.11 -p udp --dport 53 -j ACCEPT 2>/dev/null; then
        echo "[firewall] FATAL: Firewall verification failed — expected DNS rule not found"
        return 1
    fi
}

# Run if sourced or executed directly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    firewall_init
fi
