#!/usr/bin/env bats
# Tests for lib/firewall.sh

load test_helper

setup() {
    mock_iptables
    export DEVBOX_BRIDGE_SUBNET="172.20.0.0/16"
    source "${DEVBOX_ROOT}/lib/firewall.sh"
}

@test "firewall_init sets OUTPUT policy to DROP" {
    firewall_init
    [[ "$IPTABLES_CALLS" == *"-P OUTPUT DROP"* ]]
}

@test "firewall_init allows loopback" {
    firewall_init
    [[ "$IPTABLES_CALLS" == *"-A OUTPUT -o lo -j ACCEPT"* ]]
}

@test "firewall_init allows established connections" {
    firewall_init
    [[ "$IPTABLES_CALLS" == *"ESTABLISHED,RELATED"* ]]
}

@test "firewall_init allows proxy port on bridge subnet" {
    firewall_init
    [[ "$IPTABLES_CALLS" == *"-d 172.20.0.0/16 -p tcp --dport 8080 -j ACCEPT"* ]]
}

@test "firewall_init restricts DNS to Docker resolver" {
    firewall_init
    [[ "$IPTABLES_CALLS" == *"-d 127.0.0.11 -p udp --dport 53"* ]]
    [[ "$IPTABLES_CALLS" == *"-d 127.0.0.11 -p tcp --dport 53"* ]]
}

@test "firewall_init flushes OUTPUT chain first" {
    firewall_init
    [[ "$IPTABLES_CALLS" == *"-F OUTPUT"* ]]
}

@test "firewall_init uses fallback subnet when not set" {
    unset DEVBOX_BRIDGE_SUBNET
    firewall_init
    [[ "$IPTABLES_CALLS" == *"-d 172.17.0.0/16 -p tcp --dport 8080 -j ACCEPT"* ]]
}

@test "firewall_init handles missing ip6tables gracefully" {
    # Hide ip6tables so the IPv6 branch is skipped.
    ip6tables() { return 127; }
    command() {
        if [[ "$*" == *"ip6tables"* ]]; then
            return 1
        fi
        builtin command "$@"
    }
    export -f ip6tables command
    firewall_init
    # Should succeed without ip6tables — IPv4 rules still applied.
    [[ "$IPTABLES_CALLS" == *"-P OUTPUT DROP"* ]]
}
