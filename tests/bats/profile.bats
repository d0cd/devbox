#!/usr/bin/env bats
# Tests for lib/profile.sh — profile listing, variants, and validation.

load test_helper

setup() {
    setup_libs
    source "${DEVBOX_ROOT}/lib/profile.sh"
}

# --- _validate_profile_name ---

@test "validate_profile_name accepts simple name" {
    _validate_profile_name "rust"
}

@test "validate_profile_name accepts name with hyphens and underscores" {
    _validate_profile_name "my-profile_1"
}

@test "validate_profile_name rejects empty string" {
    run _validate_profile_name ""
    [ "$status" -ne 0 ]
}

@test "validate_profile_name rejects path traversal" {
    run _validate_profile_name "../etc"
    [ "$status" -ne 0 ]
}

@test "validate_profile_name rejects special characters" {
    run _validate_profile_name "rust;rm"
    [ "$status" -ne 0 ]
}

# --- profile_variants ---

@test "profile_variants returns empty for go (no variants)" {
    # Verify go.sh exists — otherwise empty output is trivially correct.
    [ -f "${DEVBOX_ROOT}/tooling/profiles/go.sh" ]
    run profile_variants "go"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "profile_variants returns ml and api for python" {
    run profile_variants "python"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qx "ml"
    echo "$output" | grep -qx "api"
}

@test "profile_variants returns wasm for rust" {
    run profile_variants "rust"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qx "wasm"
}

@test "profile_variants returns bun for node" {
    run profile_variants "node"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qx "bun"
}

@test "profile_variants returns empty for nonexistent profile" {
    run profile_variants "nonexistent"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- profile_variant_desc ---

@test "profile_variant_desc returns description for python ml" {
    run profile_variant_desc "python" "ml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PyTorch"* ]]
}

@test "profile_variant_desc returns description for python api" {
    run profile_variant_desc "python" "api"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FastAPI"* ]]
}

@test "profile_variant_desc returns description for rust wasm" {
    run profile_variant_desc "rust" "wasm"
    [ "$status" -eq 0 ]
    [[ "$output" == *"wasm-pack"* ]]
}

@test "profile_variant_desc returns empty for nonexistent variant" {
    run profile_variant_desc "python" "nonexistent"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- profile_list_detailed ---

@test "profile_list_detailed includes variant annotations for python" {
    run profile_list_detailed
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "python \[ml, api\]"
}

@test "profile_list_detailed shows go without variants" {
    run profile_list_detailed
    [ "$status" -eq 0 ]
    echo "$output" | grep -qx "go"
}

@test "profile_list_detailed includes rust with wasm variant" {
    run profile_list_detailed
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "rust \[wasm\]"
}
