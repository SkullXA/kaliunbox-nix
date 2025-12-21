#!/usr/bin/env bats

# Test suite for claim-script.sh

setup() {
    # Create temp directories
    export STATE_DIR=$(mktemp -d)
    export CONFIG_FILE="$STATE_DIR/config.json"
    export INSTALL_ID_FILE="$STATE_DIR/install_id"

    # Find a free port dynamically
    export MOCK_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()')
    export CONNECT_API_URL="http://localhost:$MOCK_PORT"

    # Source the script to get access to functions
    source "$BATS_TEST_DIRNAME/../installer/claiming/claim-script.sh"
}

teardown() {
    # Kill mock server if running
    if [[ -n "${MOCK_PID:-}" ]]; then
        kill "$MOCK_PID" 2>/dev/null || true
        wait "$MOCK_PID" 2>/dev/null || true
    fi

    # Cleanup temp directory
    rm -rf "$STATE_DIR"
}

# Helper: Start mock server that returns specified status codes in sequence
# Usage: start_mock_server "429,429,200" for DELETE
#        start_mock_server "404,404,200" "GET" for GET requests
start_mock_server() {
    local responses="$1"
    local method="${2:-DELETE}"

    python3 "$BATS_TEST_DIRNAME/mock_server.py" "$MOCK_PORT" "$method" "$responses" &
    MOCK_PID=$!

    # Wait for server to be ready
    local retries=50
    while ! curl -s "http://localhost:$MOCK_PORT/health" >/dev/null 2>&1; do
        sleep 0.05
        retries=$((retries - 1))
        if [[ $retries -eq 0 ]]; then
            echo "Mock server failed to start on port $MOCK_PORT" >&2
            return 1
        fi
    done
}

# =============================================================================
# Tests for save_configuration retry logic
# =============================================================================

@test "save_configuration succeeds on first try (HTTP 200)" {
    start_mock_server "200"

    run save_configuration '{"test": true}' "test-install-id"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Configuration receipt confirmed"* ]]
}

@test "save_configuration succeeds on first try (HTTP 204)" {
    start_mock_server "204"

    run save_configuration '{"test": true}' "test-install-id"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Configuration receipt confirmed"* ]]
}

@test "save_configuration retries on HTTP 429 and succeeds" {
    start_mock_server "429,429,429,200"

    run save_configuration '{"test": true}' "test-install-id"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Confirmation failed (HTTP 429), retrying"* ]]
    [[ "$output" == *"Configuration receipt confirmed"* ]]
}

@test "save_configuration retries on HTTP 500 and succeeds" {
    start_mock_server "500,500,200"

    run save_configuration '{"test": true}' "test-install-id"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Confirmation failed (HTTP 500), retrying"* ]]
    [[ "$output" == *"Configuration receipt confirmed"* ]]
}

@test "save_configuration warns after max retries exhausted" {
    # Server always returns 429
    start_mock_server "429,429,429,429,429,429,429,429,429,429,429"

    run save_configuration '{"test": true}' "test-install-id"

    # Should still return 0 (just warns, doesn't fail)
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"WARNING: Could not confirm configuration receipt"* ]]
}

@test "save_configuration saves config file correctly" {
    start_mock_server "200"

    local test_config='{"customer":{"first_name":"Test","last_name":"User"}}'
    run save_configuration "$test_config" "test-install-id"

    [[ "$status" -eq 0 ]]
    [[ -f "$CONFIG_FILE" ]]

    local saved_config=$(cat "$CONFIG_FILE")
    [[ "$saved_config" == "$test_config" ]]
}

@test "save_configuration sets correct file permissions" {
    start_mock_server "200"

    run save_configuration '{"test": true}' "test-install-id"

    [[ "$status" -eq 0 ]]

    # Check file permissions (should be 600 = owner read/write only)
    # macOS uses BSD stat (-f), Linux uses GNU stat (-c)
    if [[ "$(uname)" == "Darwin" ]]; then
        local perms=$(stat -f "%Lp" "$CONFIG_FILE")
    else
        local perms=$(stat -c "%a" "$CONFIG_FILE")
    fi
    [[ "$perms" == "600" ]]
}

# =============================================================================
# Tests for get_install_id
# =============================================================================

@test "get_install_id generates new ID when file doesn't exist" {
    # Skip on macOS - /proc/sys/kernel/random/uuid is Linux-only
    if [[ "$(uname)" == "Darwin" ]]; then
        skip "UUID generation uses Linux-specific /proc path"
    fi

    get_install_id

    [[ -n "$RESULT_INSTALL_ID" ]]
    [[ -f "$INSTALL_ID_FILE" ]]

    # Check it's a valid UUID format
    [[ "$RESULT_INSTALL_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

@test "get_install_id reads existing ID from file" {
    local existing_id="existing-test-id-12345"
    echo "$existing_id" > "$INSTALL_ID_FILE"

    get_install_id

    [[ "$RESULT_INSTALL_ID" == "$existing_id" ]]
}
