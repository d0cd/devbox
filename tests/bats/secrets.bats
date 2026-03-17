#!/usr/bin/env bats
# Tests for lib/secrets.sh

load test_helper

setup() {
    setup_libs
    stub_devbox_env
    CIDR_PATTERN='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$'
    export CIDR_PATTERN
    source "${DEVBOX_ROOT}/lib/commands.sh"
    source "${DEVBOX_ROOT}/lib/secrets.sh"

    # Create a secrets file for testing.
    mkdir -p "${DEVBOX_DATA}/secrets"
    cat >"${DEVBOX_DATA}/secrets/.env" <<'EOF'
# devbox secrets
ANTHROPIC_API_KEY=sk-ant-test123
OPENAI_API_KEY=sk-test456
EOF
}

teardown() {
    rm -rf "$DEVBOX_DATA" "$DEVBOX_CONFIG" 2>/dev/null || true
}

# --- secrets show ---

@test "secrets show masks values" {
    run cmd_secrets show
    [ "$status" -eq 0 ]
    [[ "$output" == *"ANTHROPIC_API_KEY=****"* ]]
    [[ "$output" != *"sk-ant-test123"* ]]
}

@test "secrets show displays empty value without mask" {
    echo "EMPTY_KEY=" >>"${DEVBOX_DATA}/secrets/.env"
    run cmd_secrets show
    [ "$status" -eq 0 ]
    [[ "$output" == *"EMPTY_KEY="* ]]
    # Empty values must NOT be masked — verify no **** for this key.
    local empty_line
    empty_line="$(echo "$output" | grep "EMPTY_KEY")"
    [[ "$empty_line" != *"****"* ]]
}

@test "secrets remove rejects invalid key format" {
    run cmd_secrets rm "lower_case"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid key"* ]]
}

# --- secrets set ---

@test "secrets set adds new key" {
    run cmd_secrets set GEMINI_API_KEY AIzaNewKey
    [ "$status" -eq 0 ]
    grep -q "GEMINI_API_KEY=AIzaNewKey" "${DEVBOX_DATA}/secrets/.env"
}

@test "secrets set updates existing key" {
    run cmd_secrets set ANTHROPIC_API_KEY sk-ant-updated
    [ "$status" -eq 0 ]
    grep -q "ANTHROPIC_API_KEY=sk-ant-updated" "${DEVBOX_DATA}/secrets/.env"
    # Should not have duplicate entries.
    local count
    count=$(grep -c "ANTHROPIC_API_KEY=" "${DEVBOX_DATA}/secrets/.env")
    [ "$count" -eq 1 ]
}

@test "secrets set rejects invalid key format" {
    run cmd_secrets set "lower_case" "value"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid key"* ]]
}

@test "secrets set rejects missing value" {
    run cmd_secrets set SOME_KEY
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage"* ]]
}

# --- secrets remove ---

@test "secrets remove deletes key" {
    run cmd_secrets rm OPENAI_API_KEY
    [ "$status" -eq 0 ]
    ! grep -q "OPENAI_API_KEY" "${DEVBOX_DATA}/secrets/.env"
    # Other keys should remain.
    grep -q "ANTHROPIC_API_KEY" "${DEVBOX_DATA}/secrets/.env"
}

@test "secrets remove nonexistent key is safe" {
    run cmd_secrets rm NONEXISTENT_KEY
    [ "$status" -eq 0 ]
    [[ "$output" == *"not found"* ]]
}

# --- secrets path ---

@test "secrets path prints file location" {
    run cmd_secrets path
    [ "$status" -eq 0 ]
    [[ "$output" == *"secrets/.env"* ]]
}
