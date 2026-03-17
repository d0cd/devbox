#!/usr/bin/env bats
# Tests for lib/allowlist.sh

load test_helper

setup() {
    setup_libs
    source "${DEVBOX_ROOT}/lib/allowlist.sh"
}

@test "validate_domain accepts simple domain" {
    _validate_domain "example.com"
}

@test "validate_domain accepts wildcard prefix" {
    _validate_domain "*.example.com"
}

@test "validate_domain accepts subdomain" {
    _validate_domain "api.sub.example.com"
}

@test "validate_domain rejects empty string" {
    run _validate_domain ""
    [ "$status" -ne 0 ]
}

@test "validate_domain rejects path traversal" {
    run _validate_domain "../etc/passwd"
    [ "$status" -ne 0 ]
}

@test "validate_domain rejects command injection" {
    run _validate_domain '; rm -rf /'
    [ "$status" -ne 0 ]
}

@test "validate_domain rejects mid-string wildcard" {
    run _validate_domain "ex*ample.com"
    [ "$status" -ne 0 ]
}

@test "allowlist_add adds domain to policy file" {
    local policy
    policy="$(create_test_policy "existing.com")"
    allowlist_add "$policy" "new.com"
    grep -q "new.com" "$policy"
    rm -f "$policy"
}

@test "allowlist_add rejects duplicate domain" {
    local policy
    policy="$(create_test_policy "existing.com")"
    run allowlist_add "$policy" "existing.com"
    # Should succeed but not add a duplicate.
    local count
    count=$(grep -c "existing.com" "$policy")
    [ "$count" -eq 1 ]
    rm -f "$policy"
}

@test "allowlist_remove removes domain from policy file" {
    local policy
    policy="$(create_test_policy "keep.com" "remove.com")"
    allowlist_remove "$policy" "remove.com"
    ! grep -q "remove.com" "$policy"
    grep -q "keep.com" "$policy"
    rm -f "$policy"
}

@test "allowlist_remove does not remove substring matches" {
    local policy
    policy="$(create_test_policy "example.com" "notexample.com")"
    allowlist_remove "$policy" "example.com"
    ! grep -q "  - example.com" "$policy"
    grep -q "notexample.com" "$policy"
    rm -f "$policy"
}

@test "allowlist_add accepts wildcard domain" {
    local policy
    policy="$(create_test_policy "existing.com")"
    allowlist_add "$policy" "*.example.com"
    grep -q '\*.example.com' "$policy"
    rm -f "$policy"
}

@test "allowlist_remove handles wildcard domain" {
    local policy
    policy="$(create_test_policy "keep.com")"
    allowlist_add "$policy" "*.remove.com"
    allowlist_remove "$policy" "*.remove.com"
    ! grep -q 'remove.com' "$policy"
    grep -q "keep.com" "$policy"
    rm -f "$policy"
}

@test "allowlist_remove nonexistent domain is safe" {
    local policy
    policy="$(create_test_policy "existing.com")"
    run allowlist_remove "$policy" "nothere.com"
    [ "$status" -eq 0 ]
    grep -q "existing.com" "$policy"
    rm -f "$policy"
}

@test "validate_domain rejects URL-like input" {
    run _validate_domain "https://example.com"
    [ "$status" -ne 0 ]
}

@test "validate_domain rejects domain with trailing dot" {
    run _validate_domain "example.com."
    [ "$status" -ne 0 ]
}

@test "validate_domain accepts single-label domain" {
    _validate_domain "localhost"
}
