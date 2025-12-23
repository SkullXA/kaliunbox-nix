{
  config,
  pkgs,
  lib,
  ...
}: let
  configFile = "/var/lib/kaliun/config.json";
  installIdFile = "/var/lib/kaliun/install_id";
  connectApiUrlFile = "/var/lib/kaliun/connect_api_url";

  tokenRefreshScript = pkgs.writeScriptBin "kaliun-token-refresh" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    CONFIG_FILE="${configFile}"
    CONNECT_API_URL=$(cat ${connectApiUrlFile} 2>/dev/null || echo "https://kaliun-connect-api-production.up.railway.app")

    if [ ! -f "$CONFIG_FILE" ]; then
      echo "No config file found, skipping token refresh"
      exit 0
    fi

    REFRESH_TOKEN=$(${pkgs.jq}/bin/jq -r '.auth.refresh_token // empty' "$CONFIG_FILE")
    if [ -z "$REFRESH_TOKEN" ]; then
      echo "No refresh token in config, skipping"
      exit 0
    fi

    ACCESS_EXPIRES=$(${pkgs.jq}/bin/jq -r '.auth.access_expires_at // empty' "$CONFIG_FILE")
    if [ -n "$ACCESS_EXPIRES" ]; then
      EXPIRES_EPOCH=$(date -d "$ACCESS_EXPIRES" +%s 2>/dev/null || echo "0")
      NOW_EPOCH=$(date +%s)
      REMAINING=$((EXPIRES_EPOCH - NOW_EPOCH))

      if [ $REMAINING -gt 86400 ]; then
        echo "Access token still valid for $((REMAINING / 86400)) days, skipping refresh"
        exit 0
      fi
    fi

    echo "Refreshing access token..."

    RESPONSE=$(${pkgs.curl}/bin/curl -s -X POST \
      -H "Content-Type: application/json" \
      -d "{\"refresh_token\": \"$REFRESH_TOKEN\"}" \
      "$CONNECT_API_URL/api/v1/installations/token/refresh" 2>/dev/null)

    if [ -z "$RESPONSE" ]; then
      echo "ERROR: Empty response from token refresh"
      exit 1
    fi

    NEW_ACCESS=$(echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.access_token // empty')
    if [ -z "$NEW_ACCESS" ]; then
      ERROR=$(echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.error // "Unknown error"')
      echo "ERROR: Token refresh failed: $ERROR"
      exit 1
    fi

    NEW_ACCESS_EXPIRES=$(echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.access_expires_at // empty')
    NEW_REFRESH=$(echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.refresh_token // empty')
    NEW_REFRESH_EXPIRES=$(echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.refresh_expires_at // empty')

    UPDATED_CONFIG=$(${pkgs.jq}/bin/jq \
      --arg at "$NEW_ACCESS" \
      --arg ae "$NEW_ACCESS_EXPIRES" \
      '.auth.access_token = $at | .auth.access_expires_at = $ae' "$CONFIG_FILE")

    if [ -n "$NEW_REFRESH" ]; then
      UPDATED_CONFIG=$(echo "$UPDATED_CONFIG" | ${pkgs.jq}/bin/jq \
        --arg rt "$NEW_REFRESH" \
        --arg re "$NEW_REFRESH_EXPIRES" \
        '.auth.refresh_token = $rt | .auth.refresh_expires_at = $re')
      echo "Refresh token was rotated"
    fi

    echo "$UPDATED_CONFIG" > "$CONFIG_FILE.tmp"
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    echo "Token refresh successful"
  '';

  configSyncScript = pkgs.writeScriptBin "kaliun-config-sync" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    CONFIG_FILE="${configFile}"
    INSTALL_ID=$(cat ${installIdFile} 2>/dev/null || echo "")
    CONNECT_API_URL=$(cat ${connectApiUrlFile} 2>/dev/null || echo "https://kaliun-connect-api-production.up.railway.app")

    if [ -z "$INSTALL_ID" ]; then
      echo "No install ID found, skipping config sync"
      exit 0
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
      echo "No config file found, skipping config sync"
      exit 0
    fi

    ACCESS_TOKEN=$(${pkgs.jq}/bin/jq -r '.auth.access_token // empty' "$CONFIG_FILE")
    if [ -z "$ACCESS_TOKEN" ]; then
      echo "No access token in config, skipping"
      exit 0
    fi

    echo "Fetching config updates..."

    HTTP_CODE=$(${pkgs.curl}/bin/curl -s -w "%{http_code}" -o /tmp/config_response.json \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      "$CONNECT_API_URL/api/v1/installations/$INSTALL_ID/config" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" = "401" ]; then
      ERROR_CODE=$(${pkgs.jq}/bin/jq -r '.code // empty' /tmp/config_response.json 2>/dev/null)
      if [ "$ERROR_CODE" = "TOKEN_EXPIRED" ]; then
        echo "Access token expired, triggering refresh..."
        ${tokenRefreshScript}/bin/kaliun-token-refresh
        rm -f /tmp/config_response.json
        exit 0
      fi
    fi

    if [ "$HTTP_CODE" != "200" ]; then
      echo "Config fetch failed with HTTP $HTTP_CODE"
      rm -f /tmp/config_response.json
      exit 1
    fi

    RESPONSE=$(cat /tmp/config_response.json)
    rm -f /tmp/config_response.json

    if ! echo "$RESPONSE" | ${pkgs.jq}/bin/jq -e '.pangolin' >/dev/null 2>&1; then
      echo "Response missing pangolin section, skipping update"
      exit 0
    fi

    NEW_CUSTOMER=$(echo "$RESPONSE" | ${pkgs.jq}/bin/jq '.customer // {}')
    NEW_PANGOLIN=$(echo "$RESPONSE" | ${pkgs.jq}/bin/jq '.pangolin // {}')

    UPDATED_CONFIG=$(${pkgs.jq}/bin/jq \
      --argjson customer "$NEW_CUSTOMER" \
      --argjson pangolin "$NEW_PANGOLIN" \
      '.customer = $customer | .pangolin = $pangolin' "$CONFIG_FILE")

    echo "$UPDATED_CONFIG" > "$CONFIG_FILE.tmp"
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    echo "Config sync successful"
  '';
in {
  environment.systemPackages = [tokenRefreshScript configSyncScript];

  systemd = {
    services = {
      kaliun-token-refresh = {
        description = "KaliunBox Token Refresh";
        serviceConfig = {
          Type = "oneshot";
          User = "root";
        };
        script = "${tokenRefreshScript}/bin/kaliun-token-refresh";
      };

      kaliun-config-sync = {
        description = "KaliunBox Config Sync";
        after = ["kaliun-token-refresh.service"];
        serviceConfig = {
          Type = "oneshot";
          User = "root";
        };
        script = "${configSyncScript}/bin/kaliun-config-sync";
      };
    };

    timers = {
      kaliun-token-refresh = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "5min";
          OnUnitActiveSec = "1d";
          Unit = "kaliun-token-refresh.service";
          Persistent = true;
        };
      };

      kaliun-config-sync = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "10min";
          OnUnitActiveSec = "1h";
          Unit = "kaliun-config-sync.service";
          Persistent = true;
        };
      };
    };
  };
}
