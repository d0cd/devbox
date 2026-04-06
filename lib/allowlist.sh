#!/usr/bin/env bash
# Allowlist management for devbox.
#
# Manages the network policy (domain allowlist) for a project.
# Changes are auto-reloaded by the proxy within DEVBOX_RELOAD_INTERVAL seconds.
set -euo pipefail

# Validate a domain string. Returns 0 if valid, 1 if not.
_validate_domain() {
    local domain="$1"
    # Allow exact domains or *. prefix wildcards only.
    if [[ "$domain" =~ ^(\*\.)?[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
        return 0
    fi
    ui_error "Invalid domain: '$domain' (must be a domain name or *.domain wildcard)"
    return 1
}

# Awk program to extract a clean domain from a YAML list entry.
# Strips leading "- ", quotes, and trailing whitespace.
_AWK_STRIP_DOMAIN='{
    line = $0
    gsub(/^[[:space:]]*-[[:space:]]+/, "", line)
    gsub(/^["'"'"']+|["'"'"']+$/, "", line)
    gsub(/[[:space:]]+$/, "", line)
}'

# Check if a domain exists in a policy file's allowed list.
# Uses Python/PyYAML for consistent parsing with the proxy enforcer.
# Falls back to awk if python3 is unavailable.
_domain_exists() {
    local policy_file="$1"
    local domain="$2"
    if command -v python3 &>/dev/null && python3 -c "import yaml" 2>/dev/null; then
        python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
sys.exit(0 if sys.argv[2] in [str(d) for d in data.get('allowed', [])] else 1)
" "$policy_file" "$domain"
    else
        awk -v d="$domain" "
        ${_AWK_STRIP_DOMAIN}
        { if (line == d) { found = 1 } }
        END { exit !found }
        " "$policy_file"
    fi
}

# Human-readable reload interval for user-facing messages.
_reload_message() {
    local interval="${DEVBOX_RELOAD_INTERVAL:-30}"
    ui_info "Changes will take effect within ${interval} seconds (policy auto-reload)."
}

# Display the current allowlist using Python/PyYAML for consistent parsing
# with the proxy enforcer. Falls back to grep/sed if python3 is unavailable.
allowlist_show() {
    local policy_file="$1"

    if [ ! -f "$policy_file" ]; then
        ui_error "Policy file not found: $policy_file"
        ui_info "Start a session first (devbox start) to create the default policy."
        return 1
    fi

    ui_header "Network Allowlist"
    ui_info "Policy file: $policy_file"
    echo ""

    if command -v python3 &>/dev/null && python3 -c "import yaml" 2>/dev/null; then
        python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
for d in data.get('allowed', []):
    print(f'  {d}')
" "$policy_file"
    else
        # Fallback: extract domains with grep/sed.
        grep -v '^#' "$policy_file" | grep -v '^version:' | grep -v '^allowed:' \
            | grep -v '^\s*$' | sed 's/^  - /  /' | sed 's/^- /  /'
    fi
    echo ""
    _reload_message
}

# Add multiple domains to the allowlist in a single atomic write.
# Uses flock to prevent concurrent modifications.
_allowlist_add_bulk() {
    local policy_file="$1"
    shift

    local tmpfile
    tmpfile="$(mktemp)"
    if [ -z "$tmpfile" ] || [ ! -f "$tmpfile" ]; then
        ui_error "Failed to create temporary file. Check disk space: df -h /tmp"
        return 1
    fi
    trap 'rm -f "$tmpfile"' RETURN

    (
        flock -w 5 9 || { ui_error "Failed to acquire policy file lock. Another devbox process may be writing. Try again."; return 1; }

        cat "$policy_file" >"$tmpfile"

        local added=0
        local domain
        for domain in "$@"; do
            if _domain_exists "$policy_file" "$domain"; then
                ui_info "Domain '$domain' is already in the allowlist."
            else
                echo "  - ${domain}" >>"$tmpfile"
                ui_info "Added '$domain' to allowlist."
                added=$((added + 1))
            fi
        done

        if [ "$added" -gt 0 ]; then
            (umask 077 && mv "$tmpfile" "$policy_file")
            _reload_message
        else
            rm -f "$tmpfile"
        fi
    ) 9>"${policy_file}.lock"

    trap - RETURN
}

# Add one or more domains to the allowlist.
allowlist_add() {
    local policy_file="$1"
    shift

    if [ $# -eq 0 ] || [ -z "$1" ]; then
        ui_error "Usage: devbox allowlist add <domain> [domain ...]"
        return 1
    fi

    if [ ! -f "$policy_file" ]; then
        ui_error "Policy file not found: $policy_file"
        ui_info "Start a session first (devbox start) to create the default policy."
        return 1
    fi

    # Validate all domains before modifying the file.
    local domain
    for domain in "$@"; do
        _validate_domain "$domain" || return 1
    done

    _allowlist_add_bulk "$policy_file" "$@"
}

# Remove a domain from the allowlist (internal helper).
_allowlist_remove_inner() {
    local policy_file="$1"
    local domain="$2"

    # Check if domain exists as an exact entry before removing.
    if ! _domain_exists "$policy_file" "$domain"; then
        ui_info "Domain '$domain' is not in the allowlist."
        return 0
    fi

    # Remove only exact matches using fixed-string comparison.
    local tmpfile
    tmpfile="$(mktemp)"
    if [ -z "$tmpfile" ] || [ ! -f "$tmpfile" ]; then
        ui_error "Failed to create temporary file. Check disk space: df -h /tmp"
        return 1
    fi
    trap 'rm -f "$tmpfile"' RETURN

    (
        flock -w 5 9 || { ui_error "Failed to acquire policy file lock. Another devbox process may be writing. Try again."; return 1; }
        awk -v d="$domain" "
        ${_AWK_STRIP_DOMAIN}
        { if (line != d) print \$0 }
        " "$policy_file" >"$tmpfile"
        (umask 077 && mv "$tmpfile" "$policy_file")
    ) 9>"${policy_file}.lock" || return 1
    trap - RETURN

    ui_info "Removed '$domain' from allowlist."
    _reload_message
}

# Remove a domain from the allowlist.
allowlist_remove() {
    local policy_file="$1"
    local domain="$2"

    if [ -z "$domain" ]; then
        ui_error "Usage: devbox allowlist remove <domain>"
        return 1
    fi

    _validate_domain "$domain" || return 1

    if [ ! -f "$policy_file" ]; then
        ui_error "Policy file not found: $policy_file"
        ui_info "Start a session first (devbox start) to create the default policy."
        return 1
    fi

    _allowlist_remove_inner "$policy_file" "$domain"
}

# Reset the allowlist to the default policy (internal helper).
_allowlist_reset_inner() {
    local policy_file="$1"
    cp "${DEVBOX_ROOT}/templates/policy.yml" "$policy_file"
    ui_info "Allowlist reset to defaults."
    _reload_message
}

# Reset the allowlist to the default policy.
allowlist_reset() {
    local policy_file="$1"

    if [ ! -f "${DEVBOX_ROOT}/templates/policy.yml" ]; then
        ui_error "Default policy template not found at ${DEVBOX_ROOT}/templates/policy.yml. Try 'devbox update' to restore it."
        return 1
    fi

    local current_count default_count
    current_count="$(grep -c '^\s*- ' "$policy_file" 2>/dev/null || echo "0")"
    default_count="$(grep -c '^\s*- ' "${DEVBOX_ROOT}/templates/policy.yml" 2>/dev/null || echo "0")"
    ui_info "Current allowlist: ${current_count} domains → Default: ${default_count} domains"

    if ! ui_confirm "Reset allowlist to defaults? This will overwrite your current policy."; then
        ui_info "Cancelled."
        return 0
    fi

    _allowlist_reset_inner "$policy_file"
}
