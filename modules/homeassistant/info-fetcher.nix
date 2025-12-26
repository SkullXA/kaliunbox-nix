# Home Assistant info fetcher service
# Periodically fetches and caches Home Assistant information from the VM
{
  config,
  pkgs,
  lib,
  ...
}: {
  systemd = {
    # Service to fetch HA info via console and cache it
    services.homeassistant-info-fetcher = {
      description = "Fetch Home Assistant info from VM";
      after = ["homeassistant-vm.service"];
      requires = ["homeassistant-vm.service"];

      serviceConfig = {
        Type = "oneshot";
      };

      script = ''
        # Wait for HA to be ready (check if web UI responds)
        for i in $(seq 1 30); do
          if ${pkgs.curl}/bin/curl -s -m 3 "http://127.0.0.1:8123/manifest.json" >/dev/null 2>&1; then
            break
          fi
          sleep 10
        done

        # Use QEMU Guest Agent to fetch HA info (works on both x86 and aarch64)
        QGA_SOCK="/var/lib/havm/qga.sock"
        if [ -S "$QGA_SOCK" ]; then
          echo "Fetching HA info via QEMU Guest Agent..."

          # Helper function to execute shell commands via QGA and get output
          qga_exec() {
            local CMD="$1"
            local EXEC_RESPONSE=$({ echo "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"/bin/sh\",\"arg\":[\"-c\",\"$CMD\"],\"capture-output\":true}}"; sleep 2; } | \
              timeout 10 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null | head -1)

            local PID=$(echo "$EXEC_RESPONSE" | ${pkgs.jq}/bin/jq -r '.return.pid // empty' 2>/dev/null)
            if [ -n "$PID" ]; then
              sleep 2
              local STATUS_RESPONSE=$({ echo "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$PID}}"; sleep 1; } | \
                timeout 8 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null | head -1)
              echo "$STATUS_RESPONSE" | ${pkgs.jq}/bin/jq -r '.return."out-data" // empty' 2>/dev/null | ${pkgs.coreutils}/bin/base64 -d 2>/dev/null
            fi
          }

          # Execute ha info command via guest agent
          EXEC_RESPONSE=$({ echo '{"execute":"guest-exec","arguments":{"path":"/usr/bin/ha","arg":["info","--raw-json"],"capture-output":true}}'; sleep 2; } | \
            timeout 10 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null | head -1)

          PID=$(echo "$EXEC_RESPONSE" | ${pkgs.jq}/bin/jq -r '.return.pid // empty' 2>/dev/null)

          if [ -n "$PID" ]; then
            sleep 2
            # Get the command output
            STATUS_RESPONSE=$({ echo "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$PID}}"; sleep 1; } | \
              timeout 8 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null | head -1)

            # Decode base64 output
            OUTPUT_B64=$(echo "$STATUS_RESPONSE" | ${pkgs.jq}/bin/jq -r '.return."out-data" // empty' 2>/dev/null)
            if [ -n "$OUTPUT_B64" ]; then
              JSON=$(echo "$OUTPUT_B64" | ${pkgs.coreutils}/bin/base64 -d 2>/dev/null)

              if [ -n "$JSON" ] && echo "$JSON" | ${pkgs.jq}/bin/jq -e '.result == "ok"' >/dev/null 2>&1; then
                echo "$JSON" > /var/lib/havm/ha-info.json
                echo "HA info cached successfully via guest agent"
              fi
            fi
          fi

          # Fetch disk usage info from inside the VM
          echo "Fetching disk usage info..."
          DISK_OUTPUT=$(qga_exec "df -B1 /mnt/data 2>/dev/null | tail -1")
          if [ -n "$DISK_OUTPUT" ]; then
            DISK_TOTAL=$(echo "$DISK_OUTPUT" | ${pkgs.gawk}/bin/awk '{print $2}')
            DISK_USED=$(echo "$DISK_OUTPUT" | ${pkgs.gawk}/bin/awk '{print $3}')
            DISK_AVAIL=$(echo "$DISK_OUTPUT" | ${pkgs.gawk}/bin/awk '{print $4}')
            if [ -n "$DISK_TOTAL" ] && [ -n "$DISK_USED" ]; then
              ${pkgs.jq}/bin/jq -n \
                --argjson total "$DISK_TOTAL" \
                --argjson used "$DISK_USED" \
                --argjson available "$DISK_AVAIL" \
                '{total_bytes: $total, used_bytes: $used, available_bytes: $available}' > /var/lib/havm/ha-disk.json
              echo "Disk info cached: $DISK_USED / $DISK_TOTAL bytes"
            fi
          fi

          # Fetch device and integration counts from .storage files
          echo "Fetching device and integration counts..."
          STORAGE_PATH="/mnt/data/supervisor/homeassistant/.storage"

          # Get device count from device registry
          DEVICE_COUNT=$(qga_exec "cat $STORAGE_PATH/core.device_registry 2>/dev/null | jq '.data.devices | length' 2>/dev/null || echo 0")
          DEVICE_COUNT=$(echo "$DEVICE_COUNT" | tr -d '[:space:]')
          if ! [[ "$DEVICE_COUNT" =~ ^[0-9]+$ ]]; then
            DEVICE_COUNT=0
          fi
          echo "Device count: $DEVICE_COUNT"

          # Get integration count from config entries
          # Count unique integration domains, excluding system integrations (hassio, go2rtc)
          INTEGRATION_COUNT=$(qga_exec "cat $STORAGE_PATH/core.config_entries 2>/dev/null | jq -r '.data.entries[].domain' | sort -u | grep -v '^hassio$' | grep -v '^go2rtc$' | wc -l")
          INTEGRATION_COUNT=$(echo "$INTEGRATION_COUNT" | tr -d '[:space:]')
          if ! [[ "$INTEGRATION_COUNT" =~ ^[0-9]+$ ]]; then
            INTEGRATION_COUNT=0
          fi
          echo "Integration count: $INTEGRATION_COUNT"

          # Save metrics to a separate file
          ${pkgs.jq}/bin/jq -n \
            --argjson device_count "$DEVICE_COUNT" \
            --argjson integration_count "$INTEGRATION_COUNT" \
            '{device_count: $device_count, integration_count: $integration_count}' > /var/lib/havm/ha-metrics.json

          echo "HA metrics cached successfully"
          exit 0
        fi

        echo "Could not fetch HA info"
      '';
    };

    # Timer to periodically update HA info
    timers.homeassistant-info-fetcher = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "30min";
        Unit = "homeassistant-info-fetcher.service";
        # Run immediately if timer was missed (e.g., after rebuild)
        Persistent = true;
      };
    };
  };
}
