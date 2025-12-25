{
  config,
  pkgs,
  lib,
  ...
}: let
  logScript = pkgs.writeScriptBin "kaliun-log-reporter" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    CONFIG_FILE="/var/lib/kaliun/config.json"
    INSTALL_ID=$(cat /var/lib/kaliun/install_id 2>/dev/null || echo "unknown")
    CONNECT_API_URL=$(cat /var/lib/kaliun/connect_api_url 2>/dev/null || echo "https://kaliun-connect-api-production.up.railway.app")
    LAST_SENT_FILE="/var/lib/kaliun/last_log_cursor"

    if [ ! -f "$CONFIG_FILE" ]; then
      echo "ERROR: Configuration file not found"
      exit 1
    fi

    AUTH_TOKEN=$(${pkgs.jq}/bin/jq -r '.auth.access_token // empty' "$CONFIG_FILE")

    if [ -z "$AUTH_TOKEN" ]; then
      echo "ERROR: No auth token in configuration"
      exit 1
    fi

    echo "Collecting system logs..."

    # Services to collect logs from
    SERVICES=(
      "homeassistant-vm.service"
      "havm-ensure-image.service"
      "homeassistant-info-fetcher.service"
      "homeassistant-proxy-setup.service"
      "homeassistant-health-check.service"
      "homeassistant-watchdog.service"
      "container@newt-agent.service"
      "kaliun-health-reporter.service"
      "kaliun-auto-update.service"
      "management-console.service"
      "kaliunbox-boot-health.service"
      "kaliunbox-first-boot.service"
    )

    # Get cursor from last run (to only send new logs)
    CURSOR=""
    if [ -f "$LAST_SENT_FILE" ]; then
      CURSOR=$(cat "$LAST_SENT_FILE")
    fi

    # Collect logs from each service
    ALL_LOGS=""
    for SERVICE in "''${SERVICES[@]}"; do
      echo "Collecting logs from $SERVICE..."
      
      if [ -n "$CURSOR" ]; then
        SERVICE_LOGS=$(${pkgs.systemd}/bin/journalctl -u "$SERVICE" --after-cursor="$CURSOR" -o json --no-pager 2>/dev/null || echo "")
      else
        # First run: only get last 100 lines per service
        SERVICE_LOGS=$(${pkgs.systemd}/bin/journalctl -u "$SERVICE" -n 100 -o json --no-pager 2>/dev/null || echo "")
      fi
      
      if [ -n "$SERVICE_LOGS" ]; then
        ALL_LOGS="$ALL_LOGS$SERVICE_LOGS"
      fi
    done

    # Also collect any ERROR or WARNING level logs from the system
    echo "Collecting system errors/warnings..."
    if [ -n "$CURSOR" ]; then
      SYSTEM_LOGS=$(${pkgs.systemd}/bin/journalctl -p warning --after-cursor="$CURSOR" -o json --no-pager 2>/dev/null || echo "")
    else
      SYSTEM_LOGS=$(${pkgs.systemd}/bin/journalctl -p warning -n 50 -o json --no-pager 2>/dev/null || echo "")
    fi
    
    if [ -n "$SYSTEM_LOGS" ]; then
      ALL_LOGS="$ALL_LOGS$SYSTEM_LOGS"
    fi

    # Get current cursor for next run
    NEW_CURSOR=$(${pkgs.systemd}/bin/journalctl --show-cursor -n 0 2>/dev/null | ${pkgs.gnugrep}/bin/grep -oP '(?<=cursor: ).*' || echo "")

    # If no logs, exit early
    if [ -z "$ALL_LOGS" ]; then
      echo "No new logs to send"
      if [ -n "$NEW_CURSOR" ]; then
        echo "$NEW_CURSOR" > "$LAST_SENT_FILE"
      fi
      exit 0
    fi

    # Convert journalctl JSON lines to our log format
    # Parse each JSON line and transform it
    LOGS_ARRAY=$(echo "$ALL_LOGS" | ${pkgs.jq}/bin/jq -s -c '
      [.[] | select(. != null and .MESSAGE != null) | {
        timestamp: (.__REALTIME_TIMESTAMP | tonumber / 1000000 | todate),
        level: (
          if .PRIORITY == "0" or .PRIORITY == "1" or .PRIORITY == "2" or .PRIORITY == "3" then "error"
          elif .PRIORITY == "4" then "warning"
          elif .PRIORITY == "7" then "debug"
          else "info"
          end
        ),
        # Prefer systemd unit name, fall back to syslog identifier so we still categorize logs correctly
        # (some stdout logs can lack _SYSTEMD_UNIT depending on how they are emitted/forwarded).
        service: (._SYSTEMD_UNIT // .SYSLOG_IDENTIFIER // "system"),
        message: .MESSAGE
      }] | unique_by(.timestamp + .message) | sort_by(.timestamp) | .[-500:]
    ' 2>/dev/null || echo "[]")

    LOG_COUNT=$(echo "$LOGS_ARRAY" | ${pkgs.jq}/bin/jq 'length')
    echo "Collected $LOG_COUNT log entries"

    if [ "$LOG_COUNT" = "0" ]; then
      echo "No valid log entries to send"
      if [ -n "$NEW_CURSOR" ]; then
        echo "$NEW_CURSOR" > "$LAST_SENT_FILE"
      fi
      exit 0
    fi

    # Build payload
    PAYLOAD=$(${pkgs.jq}/bin/jq -n \
      --argjson logs "$LOGS_ARRAY" \
      '{logs: $logs}')

    echo "Sending $LOG_COUNT log entries to Connect API..."

    # Post to Connect API
    ENDPOINT="$CONNECT_API_URL/api/v1/installations/$INSTALL_ID/logs"
    
    HTTP_CODE=$(${pkgs.curl}/bin/curl -s -w "%{http_code}" -o /tmp/log_response.json \
      --connect-timeout 10 \
      --max-time 60 \
      -X POST \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $AUTH_TOKEN" \
      -d "$PAYLOAD" \
      "$ENDPOINT" 2>&1) || true

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "204" ]; then
      echo "Logs sent successfully (HTTP $HTTP_CODE)"
      # Save cursor for next run
      if [ -n "$NEW_CURSOR" ]; then
        echo "$NEW_CURSOR" > "$LAST_SENT_FILE"
      fi
      exit 0
    else
      echo "Failed to send logs (HTTP $HTTP_CODE)"
      if [ -f /tmp/log_response.json ] && [ -s /tmp/log_response.json ]; then
        echo "Response: $(head -c 500 /tmp/log_response.json)"
      fi
      exit 1
    fi
  '';
in {
  environment.systemPackages = [logScript];

  systemd.services.kaliun-log-reporter = {
    description = "KaliunBox Log Reporter";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target"];
    wants = ["network-online.target"];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      RemainAfterExit = false;
    };
    script = "${logScript}/bin/kaliun-log-reporter";
  };

  systemd.timers.kaliun-log-reporter = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "2min";  # Send logs every 2 minutes for better visibility
      Unit = "kaliun-log-reporter.service";
      Persistent = true;
    };
  };
}