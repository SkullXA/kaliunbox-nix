#
# KaliunBox Claiming Script
# Registers installation and waits for claiming via web portal
#

set -euo pipefail

# Redirect stdout and stderr to journald via systemd-cat (if available)
# Only explicit writes to /dev/tty1 will show on screen
# Skip redirection in test mode or when systemd-cat is not available
if [[ -z "${BATS_TEST_DIRNAME:-}" ]] && command -v systemd-cat &>/dev/null; then
    exec 1> >(systemd-cat -t kaliunbox-claiming) 2>&1
fi

# Configuration (allow overrides for testing)
CONNECT_API_URL="${CONNECT_API_URL:-https://kaliun-connect-api-production.up.railway.app}"
STATE_DIR="${STATE_DIR:-/var/lib/kaliun}"
CONFIG_FILE="${CONFIG_FILE:-$STATE_DIR/config.json}"
INSTALL_ID_FILE="${INSTALL_ID_FILE:-$STATE_DIR/install_id}"
API_URL_FILE="${API_URL_FILE:-$STATE_DIR/connect_api_url}"

# Global variables for function return values
RESULT_INSTALL_ID=""
RESULT_CLAIM_CODE=""
RESULT_CONFIG=""

# Ensure directories exist (skip in test mode if directory already exists)
if [[ ! -d "$STATE_DIR" ]]; then
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"  # Secure config directory
fi

# Persist custom API URL for other services
if [ "$CONNECT_API_URL" != "https://kaliun-connect-api-production.up.railway.app" ]; then
    echo "$CONNECT_API_URL" > "$API_URL_FILE"
    chmod 600 "$API_URL_FILE"
fi

error() {
    echo "ERROR: $*"
    exit 1
}

# Generate or read installation ID
# Sets RESULT_INSTALL_ID
get_install_id() {
    if [ -f "$INSTALL_ID_FILE" ]; then
        RESULT_INSTALL_ID=$(cat "$INSTALL_ID_FILE")
    else
        RESULT_INSTALL_ID=$(cat /proc/sys/kernel/random/uuid)
        echo "$RESULT_INSTALL_ID" > "$INSTALL_ID_FILE"
        echo "Generated new installation ID: $RESULT_INSTALL_ID"
    fi
}

# Register with Connect API and get claim code
# Sets RESULT_CLAIM_CODE on success, returns 1 on failure
register_installation() {
    local install_id="$1"
    local hostname="kaliunbox"

    echo "Registering installation with Connect API..."
    echo "Endpoint: $CONNECT_API_URL/api/v1/installations/register"
    echo "Payload: {\"install_id\": \"$install_id\", \"hostname\": \"$hostname\"}"

    # Capture HTTP status and response with retries
    local temp_file=$(mktemp)
    local temp_err=$(mktemp)
    local http_code
    local retry_count=0
    local max_retries=10
    local spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )

    while [ $retry_count -lt $max_retries ]; do
        # Show attempt on screen with spinner
        local spin_idx=$((retry_count % 10))
        printf "\r${spinner[$spin_idx]} Registering (attempt %d/%d)..." "$((retry_count + 1))" "$max_retries" > /dev/tty1

        # Log the actual URL being called
        echo "Attempting: POST $CONNECT_API_URL/api/v1/installations/register"

        http_code=$(curl -s -w "%{http_code}" -o "$temp_file" --max-time 15 \
            -X POST "$CONNECT_API_URL/api/v1/installations/register" \
            -H "Content-Type: application/json" \
            -d "{\"install_id\": \"$install_id\", \"hostname\": \"$hostname\"}" 2>"$temp_err" || echo "000")

        # Log curl errors if any
        if [ -s "$temp_err" ]; then
            echo "Curl error: $(cat "$temp_err")"
        fi

        # Break on success or client errors (don't retry those)
        if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
            echo "Registration successful (HTTP $http_code)"
            printf "\r✓ Registration successful!          \n" > /dev/tty1
            break
        elif [ "$http_code" = "400" ] || [ "$http_code" = "404" ]; then
            echo "Client error (HTTP $http_code), not retrying"
            printf "\r✗ Registration failed (HTTP %s)     \n" "$http_code" > /dev/tty1
            break
        fi

        # Retry on network errors (000) or server errors (5xx)
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            echo "Network/server error (HTTP $http_code, attempt $retry_count/$max_retries), retrying in 3 seconds..."
            sleep 3
        else
            echo "Max retries reached with HTTP $http_code"
            printf "\r✗ Registration failed after %d attempts\n" "$max_retries" > /dev/tty1
        fi
    done

    local response
    response=$(cat "$temp_file")
    rm -f "$temp_file" "$temp_err"

    echo "Registration response: HTTP $http_code"
    echo "Response body: $response"

    # Check HTTP status
    case "$http_code" in
        200|201)
            # Success
            ;;
        400)
            echo "ERROR: Bad request (400) - check API payload format"
            echo "ERROR: Registration failed - invalid request format" > /dev/tty1
            return 1
            ;;
        404)
            echo "ERROR: Endpoint not found (404)"
            echo "ERROR: API endpoint not found" > /dev/tty1
            return 1
            ;;
        000)
            echo "ERROR: Network error connecting to $CONNECT_API_URL"
            echo "ERROR: Cannot reach API server" > /dev/tty1
            return 1
            ;;
        *)
            echo "ERROR: Unexpected HTTP status $http_code"
            return 1
            ;;
    esac

    if [ -z "$response" ]; then
        echo "ERROR: Empty response from registration API"
        return 1
    fi

    # Parse claim code from response
    RESULT_CLAIM_CODE=$(echo "$response" | jq -r '.claim_code // empty' 2>/dev/null)

    if [ -z "$RESULT_CLAIM_CODE" ]; then
        echo "ERROR: Invalid response from registration API (no claim code)"
        echo "Expected field: claim_code"
        return 1
    fi

    echo "Registration successful, claim code: $RESULT_CLAIM_CODE"
}

# Display claiming screen with QR code and poll for configuration
# This function takes over tty1 and refreshes the display while polling
# Sets RESULT_CONFIG on success
show_claiming_screen_and_wait() {
    local install_id="$1"
    local claim_code="$2"
    local claim_url="$CONNECT_API_URL/claim/$claim_code"
    local max_wait_seconds=600  # 10 minutes total
    local elapsed=0
    local poll_interval=10

    echo "Displaying claiming screen and waiting for claim..."

    while [ $elapsed -lt $max_wait_seconds ]; do
        # Clear screen and redraw completely
        tput clear > /dev/tty1 2>/dev/null || true

        # Left side - text content
        {
            echo ""
            echo ""
        echo "  ========================================"
        echo "  Kaliun Installation Registration"
        echo "  ========================================"
            echo ""
            echo ""
            echo "  Scan this QR code to complete setup:"
            echo ""
            echo "  Or visit:"
            echo "  $CONNECT_API_URL/claim"
            echo ""
            echo "  Enter code: $claim_code"
            echo ""
            echo ""
            echo "  Waiting for registration..."
            echo ""
            echo ""
            echo "  Need console access?"
            echo "  Press Alt+F2"
            echo ""
        } > /dev/tty1

        # Right side - QR code positioned at column 50, starting at row 6
        if qr_output=$(qrencode -t ANSI256 -m 1 -s 1 --level=L "$claim_url" 2>&1); then
            local row=6
            echo "$qr_output" | while IFS= read -r line; do
                # Use ANSI escape sequence for positioning: ESC[row;colH
                printf "\033[${row};50H%s" "$line"
                row=$((row + 1))
            done > /dev/tty1
        else
            # Fallback if qrencode fails
            echo "  (QR code display not supported on this terminal)" > /dev/tty1
        fi

        # Check if claimed (poll API)
        local http_code
        local response
        local temp_file=$(mktemp)

        http_code=$(curl -s -w "%{http_code}" -o "$temp_file" --max-time 10 \
            "$CONNECT_API_URL/api/v1/installations/$install_id/config" 2>/dev/null || echo "000")
        response=$(cat "$temp_file")
        rm -f "$temp_file"

        echo "Poll attempt: HTTP $http_code (elapsed: ${elapsed}s)"

        case "$http_code" in
            200)
                # Check if config is ready (has pangolin section)
                if echo "$response" | jq empty 2>/dev/null; then
                    if echo "$response" | jq -e '.pangolin' >/dev/null 2>&1; then
                        echo "Installation claimed successfully!"
                        RESULT_CONFIG="$response"
                        return 0
                    else
                        echo "Config response missing pangolin section (not ready yet)"
                    fi
                fi
                ;;
            404)
                # Not claimed yet - this is normal
                echo "Installation not claimed yet (404)"
                ;;
            400|401|403)
                # Client errors - fail
                echo "ERROR: Client error HTTP $http_code"
                echo "Response: $response"
                tput clear > /dev/tty1 2>/dev/null || true
                {
                    echo ""
                    echo "  ========================================"
                    echo "  ERROR: Registration Failed"
                    echo "  ========================================"
                    echo ""
                    echo "  HTTP Error: $http_code"
                    echo ""
                    echo "  Check: journalctl -t kaliunbox-claiming"
                    echo ""
                    echo "  Press Alt+F2 for console access"
                } > /dev/tty1
                sleep 30
                error "Client error during polling: HTTP $http_code"
                ;;
            000)
                # Network error - show on screen briefly
                echo "WARNING: Network error"
                {
                    tput cup 20 0
                    echo "  Network error, retrying..."
                } > /dev/tty1 2>/dev/null || true
                ;;
        esac

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    # Timeout
    tput clear > /dev/tty1 2>/dev/null || true
    {
        echo ""
        echo "  ========================================"
        echo "  ERROR: Timeout"
        echo "  ========================================"
        echo ""
        echo "  Registration not completed within 10 minutes"
        echo ""
        echo "  Please check your network and try again"
        echo ""
        echo "  Press Alt+F2 for console access"
    } > /dev/tty1
    error "Timeout waiting for claim (waited ${max_wait_seconds}s)"
}

# Save configuration and confirm receipt
save_configuration() {
    local config="$1"
    local install_id="$2"

    echo "Saving configuration to $CONFIG_FILE"

    # Save config
    echo "$config" > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    echo "Configuration saved"

    # Confirm receipt with DELETE request (retry until success)
    echo "Confirming configuration receipt..."
    local max_retries=10
    local retry=0

    while [ $retry -lt $max_retries ]; do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE --max-time 10 \
            "$CONNECT_API_URL/api/v1/installations/$install_id/config" 2>/dev/null)

        if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
            echo "Configuration receipt confirmed"
            return 0
        fi

        echo "Confirmation failed (HTTP $http_code), retrying..."
        sleep 2
        retry=$((retry + 1))
    done

    echo "WARNING: Could not confirm configuration receipt after $max_retries attempts"
}

# Display success message
show_success() {
    local config="$1"

    local customer_name
    local customer_contact
    customer_name=$(echo "$config" | jq -r '.customer.name // "Unknown"' 2>/dev/null | head -c 40)
    customer_contact=$(echo "$config" | jq -r '.customer.email // "Unknown"' 2>/dev/null | head -c 40)

    tput clear > /dev/tty1 2>/dev/null || true

    {
        echo ""
        echo ""
        echo "  ========================================"
        echo "  Installation Registered Successfully!"
        echo "  ========================================"
        echo ""
        echo "  Customer: $customer_name"
        echo "  Contact:  $customer_contact"
        echo ""
        echo ""
        echo "  Proceeding to installation..."
        echo ""
    } > /dev/tty1

    # Brief pause to show success message
    sleep 2 2>/dev/null || true
}

# Main claiming flow
main() {
    echo "=== Starting KaliunBox Claiming Process ==="
    echo "Connect API URL: $CONNECT_API_URL"

    # Check if already claimed
    if [ -f "$CONFIG_FILE" ]; then
        echo "Configuration already exists, skipping claiming"
        show_success "$(cat "$CONFIG_FILE")"
        return 0
    fi

    # Get installation ID
    get_install_id

    # Register and get claim code (retries handled inside register_installation)
    if ! register_installation "$RESULT_INSTALL_ID"; then
        error "Failed to register installation"
    fi

    if [ -z "$RESULT_CLAIM_CODE" ]; then
        error "Registration returned empty claim code"
    fi

    # Show claiming screen and wait for configuration
    # This function combines display + polling in a loop
    show_claiming_screen_and_wait "$RESULT_INSTALL_ID" "$RESULT_CLAIM_CODE"

    # Save configuration and confirm
    save_configuration "$RESULT_CONFIG" "$RESULT_INSTALL_ID"

    # Show success message
    show_success "$RESULT_CONFIG"

    echo "=== Claiming Process Completed Successfully ==="
}

# Run main function only if not being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
