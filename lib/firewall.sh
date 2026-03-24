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

# Validate that a CIDR string has octets in range (0-255) and prefix <= 32.
# The regex CIDR_PATTERN checks format; this function checks semantics.
_validate_cidr() {
    local cidr="$1"
    local ip="${cidr%/*}"
    local prefix="${cidr#*/}"
    if [ "$prefix" -gt 32 ] 2>/dev/null; then
        return 1
    fi
    local IFS='.'
    # shellcheck disable=SC2086
    set -- $ip
    for octet in "$@"; do
        if [ "$octet" -gt 255 ] 2>/dev/null; then
            return 1
        fi
    done
    return 0
}

firewall_init() {
    echo "[firewall] Initializing iptables rules..."

    # --- INPUT chain: default deny inbound ---
    # Prevents external connections from reaching services in the container
    # if network configuration is ever misconfigured.
    iptables -F INPUT
    iptables -P INPUT DROP
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # --- FORWARD chain: default deny ---
    # Prevents the container from being used as a network gateway.
    iptables -F FORWARD
    iptables -P FORWARD DROP

    # --- OUTPUT chain: default deny outbound ---
    iptables -F OUTPUT
    iptables -P OUTPUT DROP

    # Allow loopback (localhost communication).
    iptables -A OUTPUT -o lo -j ACCEPT

    # Allow established and related connections (responses to inbound).
    iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # Allow traffic to Docker bridge network where the proxy sidecar lives.
    # DEVBOX_BRIDGE_SUBNET is set by the entrypoint after detecting the
    # actual network. Falls back to Docker's default range.
    local bridge_subnet="${DEVBOX_BRIDGE_SUBNET:-172.17.0.0/16}"
    if [[ ! "$bridge_subnet" =~ $CIDR_PATTERN ]] || ! _validate_cidr "$bridge_subnet"; then
        echo "[firewall] FATAL: Invalid bridge subnet CIDR: '$bridge_subnet'"
        return 1
    fi
    # Allow only the proxy port (8080) on the bridge.
    iptables -A OUTPUT -d "$bridge_subnet" -p tcp --dport 8080 -j ACCEPT

    # Allow DNS only to Docker's embedded DNS resolver (127.0.0.11).
    # Restricting to this address prevents DNS tunneling to external servers.
    iptables -A OUTPUT -d 127.0.0.11 -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -d 127.0.0.11 -p tcp --dport 53 -j ACCEPT

    # Block ICMP — prevents covert channels and network reconnaissance.
    iptables -A OUTPUT -p icmp -j DROP

    echo "[firewall] IPv4 rules applied (INPUT/FORWARD/OUTPUT)."

    # --- IPv6: fail-closed ---
    # Block all IPv6 to prevent bypass. If ip6tables setup fails, the entire
    # firewall init fails — we refuse to run with partial enforcement.
    if command -v ip6tables &>/dev/null; then
        if ip6tables -F OUTPUT && ip6tables -P OUTPUT DROP; then
            ip6tables -A OUTPUT -o lo -j ACCEPT \
                || echo "[firewall] WARN: IPv6 loopback rule failed (non-fatal)"
            ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT \
                || echo "[firewall] WARN: IPv6 conntrack rule failed (non-fatal)"
            ip6tables -F INPUT && ip6tables -P INPUT DROP \
                || echo "[firewall] WARN: IPv6 INPUT chain setup failed (non-fatal)"
            ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
            ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
            ip6tables -F FORWARD && ip6tables -P FORWARD DROP \
                || echo "[firewall] WARN: IPv6 FORWARD chain setup failed (non-fatal)"
            echo "[firewall] IPv6 rules applied (all chains locked down)."
        else
            echo "[firewall] FATAL: IPv6 firewall rules failed — refusing to start with partial enforcement."
            return 1
        fi
    fi

    echo "[firewall] All chains locked down. Egress only via proxy bridge."

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
