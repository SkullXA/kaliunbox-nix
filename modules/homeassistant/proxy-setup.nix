# Home Assistant proxy setup service
# Configures Home Assistant for reverse proxy support
{
  config,
  pkgs,
  lib,
  ...
}: {
  # Service to configure HA for reverse proxy support
  # Runs on every boot to ensure config is present (user may remove it)
  systemd.services.homeassistant-proxy-setup = {
    description = "Configure Home Assistant for reverse proxy";
    after = ["homeassistant-vm.service"];
    requires = ["homeassistant-vm.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
            QGA_SOCK="/var/lib/havm/qga.sock"

            # Wait for guest agent to be ready
            echo "Waiting for Home Assistant VM to be ready..."
            for i in $(seq 1 60); do
              PING=$({ echo '{"execute":"guest-ping"}'; sleep 1; } | \
                timeout 5 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null | head -1)
              if echo "$PING" | ${pkgs.jq}/bin/jq -e '.return' >/dev/null 2>&1; then
                break
              fi
              sleep 5
            done

            # For user-mode networking (SLIRP) with port forwarding, use localhost directly
            # This is the case for aarch64/nested VMs where bridge networking isn't available
            # Check if QEMU is using user-mode networking by looking at the process args
            # The netdev argument looks like: -netdev user,id=net0,hostfwd=...
            QEMU_ARGS=$(${pkgs.procps}/bin/ps aux | ${pkgs.gnugrep}/bin/grep -E 'qemu.*homeassistant' | ${pkgs.gnugrep}/bin/grep -v grep | head -1)
            if echo "$QEMU_ARGS" | ${pkgs.gnugrep}/bin/grep -qE 'netdev (user,|slirp)'; then
              echo "Detected SLIRP/user-mode networking, using localhost for Home Assistant"
              HA_IP="127.0.0.1"
            else
              # Get VM IP address via guest agent (handles bridge networking)
              # Priority: Look for 192.168.x.x first (bridge network), then fall back to any non-internal IP
              echo "Getting Home Assistant VM IP address..."
              HA_IP=""
              for i in $(seq 1 30); do
                # First try to get a 192.168.x.x IP (most likely the bridge network)
                # Filter out 127.x.x.x (localhost), 172.x.x.x (Docker), and 10.x.x.x (QEMU internal)
                IP_CMD="ip -4 addr show | grep 'inet ' | grep -v '127\.' | grep -v '172\.' | grep -v '10\.' | head -1 | awk '{print \$2}' | cut -d/ -f1"
                EXEC_RESPONSE=$({ echo "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"/bin/sh\",\"arg\":[\"-c\",\"$IP_CMD\"],\"capture-output\":true}}"; sleep 2; } | \
                  timeout 10 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null | head -1)
                PID=$(echo "$EXEC_RESPONSE" | ${pkgs.jq}/bin/jq -r '.return.pid // empty' 2>/dev/null)
                if [ -n "$PID" ]; then
                  sleep 2
                  STATUS_RESPONSE=$({ echo "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$PID}}"; sleep 1; } | \
                    timeout 8 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null | head -1)
                  OUTPUT_B64=$(echo "$STATUS_RESPONSE" | ${pkgs.jq}/bin/jq -r '.return."out-data" // empty' 2>/dev/null)
                  if [ -n "$OUTPUT_B64" ]; then
                    HA_IP=$(echo "$OUTPUT_B64" | ${pkgs.coreutils}/bin/base64 -d 2>/dev/null | tr -d '[:space:]')
                    if [ -n "$HA_IP" ]; then
                      echo "Found Home Assistant VM IP: $HA_IP"
                      break
                    fi
                  fi
                fi
                sleep 5
              done

              # Fallback: try to detect VM IP from host's ARP table (bridge networking)
              if [ -z "$HA_IP" ]; then
                echo "Guest agent IP detection failed, trying ARP table..."
                if ${pkgs.iproute2}/bin/ip link show br-haos >/dev/null 2>&1; then
                  MAC_FILE="/var/lib/havm/mac_address"
                  if [ -f "$MAC_FILE" ]; then
                    VM_MAC=$(cat "$MAC_FILE")
                    HA_IP=$(${pkgs.iproute2}/bin/ip neigh show dev br-haos | ${pkgs.gnugrep}/bin/grep -i "$VM_MAC" | ${pkgs.gnugrep}/bin/grep -v FAILED | ${pkgs.gawk}/bin/awk '{print $1}' | head -1)
                    if [ -n "$HA_IP" ]; then
                      echo "Found VM IP from bridge ARP table: $HA_IP"
                    fi
                  fi
                fi
              fi

              # Final fallback to localhost (user-mode networking)
              if [ -z "$HA_IP" ]; then
                echo "Could not detect VM IP, falling back to localhost"
                HA_IP="127.0.0.1"
              fi
            fi

            # Wait for HA to be fully started (supervisor ready)
            echo "Waiting for Home Assistant to be fully started on $HA_IP..."
            for i in $(seq 1 30); do
              if ${pkgs.curl}/bin/curl -s -m 3 "http://$HA_IP:8123/manifest.json" >/dev/null 2>&1; then
                break
              fi
              sleep 10
            done
            sleep 10  # Extra wait for config to be accessible

            # CRITICAL: Wait for HAOS to complete first-boot initialization
            # On fresh installs, HAOS creates configuration.yaml with default includes.
            # If we write to configuration.yaml before this happens, HAOS sees the file
            # exists and skips initialization, resulting in missing automations.yaml, etc.
            #
            # Optimization: Use a marker file to skip this check on subsequent boots.
            # The marker is created after first successful initialization and deleted
            # when the VM qcow2 is recreated.
            HA_CONFIG="/mnt/data/supervisor/homeassistant/configuration.yaml"
            HA_INIT_MARKER="/var/lib/havm/ha_initialized"

            if [ -f "$HA_INIT_MARKER" ]; then
              echo "HAOS initialization marker found - skipping first-boot detection"
            else
              echo "Waiting for HAOS to complete first-boot initialization..."
              for i in $(seq 1 60); do
                # Check if configuration.yaml exists and has content (file size > 10 bytes)
                # Use stat to get file size - simpler and more reliable than grep via guest-exec
                CHECK_INIT_CMD="test -s $HA_CONFIG && stat -c%s $HA_CONFIG 2>/dev/null || echo 0"
                EXEC_RESPONSE=$({ echo "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"/bin/sh\",\"arg\":[\"-c\",\"$CHECK_INIT_CMD\"],\"capture-output\":true}}"; sleep 2; } | \
                  timeout 10 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null | head -1)

                PID=$(echo "$EXEC_RESPONSE" | ${pkgs.jq}/bin/jq -r '.return.pid // empty' 2>/dev/null)
                if [ -n "$PID" ]; then
                  sleep 2
                  STATUS_RESPONSE=$({ echo "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$PID}}"; sleep 1; } | \
                    timeout 8 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null | head -1)

                  OUTPUT_B64=$(echo "$STATUS_RESPONSE" | ${pkgs.jq}/bin/jq -r '.return."out-data" // empty' 2>/dev/null)
                  if [ -n "$OUTPUT_B64" ]; then
                    FILE_SIZE=$(echo "$OUTPUT_B64" | ${pkgs.coreutils}/bin/base64 -d 2>/dev/null | tr -d '[:space:]')
                    # If file has content (size > 10 bytes), initialization is complete
                    if [ -n "$FILE_SIZE" ] && [ "$FILE_SIZE" -gt 10 ] 2>/dev/null; then
                      echo "HAOS first-boot initialization complete (config file size: $FILE_SIZE bytes)"
                      # Create marker for future boots
                      touch "$HA_INIT_MARKER"
                      echo "Created initialization marker at $HA_INIT_MARKER"
                      break
                    fi
                  fi
                fi
                echo "Waiting for HAOS to create default configuration... ($i/60)"
                sleep 5
              done
            fi

            echo "Checking current configuration..."
            CHECK_CMD="grep -q 'use_x_forwarded_for' $HA_CONFIG 2>/dev/null && echo EXISTS || echo MISSING"

            CONFIG_EXISTS=false
            for check_attempt in $(seq 1 3); do
              EXEC_RESPONSE=$({ echo "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"/bin/sh\",\"arg\":[\"-c\",\"$CHECK_CMD\"],\"capture-output\":true}}"; sleep 2; } | \
                timeout 10 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null | head -1)

              PID=$(echo "$EXEC_RESPONSE" | ${pkgs.jq}/bin/jq -r '.return.pid // empty' 2>/dev/null)
              if [ -n "$PID" ]; then
                sleep 2
                STATUS_RESPONSE=$({ echo "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$PID}}"; sleep 1; } | \
                  timeout 8 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null | head -1)

                OUTPUT_B64=$(echo "$STATUS_RESPONSE" | ${pkgs.jq}/bin/jq -r '.return."out-data" // empty' 2>/dev/null)
                if [ -n "$OUTPUT_B64" ]; then
                  RESULT=$(echo "$OUTPUT_B64" | ${pkgs.coreutils}/bin/base64 -d 2>/dev/null | tr -d '[:space:]')
                  echo "Config check result: $RESULT"
                  if [ "$RESULT" = "EXISTS" ]; then
                    CONFIG_EXISTS=true
                    break
                  elif [ "$RESULT" = "MISSING" ]; then
                    break
                  fi
                fi
              fi
              echo "Config check attempt $check_attempt failed, retrying..."
              sleep 3
            done

            if [ "$CONFIG_EXISTS" = "true" ]; then
              echo "HTTP configuration already exists in configuration.yaml"
              exit 0
            fi

            # Add reverse proxy configuration to HA
            echo "Adding reverse proxy configuration to Home Assistant..."

            # The configuration to append (base64 encoded to safely pass through JSON)
            HTTP_CONFIG_B64=$(${pkgs.coreutils}/bin/base64 -w0 << 'CONFIGEOF'

      # ==============================================================================
      # MANAGED BY SELORABOX - DO NOT EDIT THIS SECTION
      # This configuration is automatically maintained by KaliunBox for reverse proxy
      # support. Manual changes will be overwritten on system updates.
      # ==============================================================================
      http:
        use_x_forwarded_for: true
        trusted_proxies:
          - 10.0.2.0/24
          - 172.16.0.0/12
          - 192.168.0.0/16
          - 127.0.0.0/8
      CONFIGEOF
      )

            # Build command - decode base64 and append to config
            APPEND_CMD="echo $HTTP_CONFIG_B64 | base64 -d >> $HA_CONFIG"

            # Build JSON using jq to ensure proper escaping
            EXEC_JSON=$(${pkgs.jq}/bin/jq -n --arg cmd "$APPEND_CMD" '{
              execute: "guest-exec",
              arguments: {
                path: "/bin/sh",
                arg: ["-c", $cmd],
                "capture-output": true
              }
            }')

            EXEC_RESPONSE=$({ echo "$EXEC_JSON"; sleep 2; } | \
              timeout 10 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null | head -1)

            PID=$(echo "$EXEC_RESPONSE" | ${pkgs.jq}/bin/jq -r '.return.pid // empty' 2>/dev/null)
            if [ -z "$PID" ]; then
              # Check if error is in response
              ERROR_MSG=$(echo "$EXEC_RESPONSE" | ${pkgs.jq}/bin/jq -r '.error.desc // empty' 2>/dev/null)
              if [ -n "$ERROR_MSG" ]; then
                echo "Guest agent error: $ERROR_MSG"
              else
                echo "Guest agent response: $EXEC_RESPONSE"
              fi
              echo "ERROR: Failed to execute config append command"
              exit 1
            fi

            sleep 2
            STATUS_RESPONSE=$({ echo "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$PID}}"; sleep 1; } | \
              timeout 8 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null | head -1)

            EXIT_CODE=$(echo "$STATUS_RESPONSE" | ${pkgs.jq}/bin/jq -r '.return.exitcode // 1' 2>/dev/null)
            if [ "$EXIT_CODE" != "0" ]; then
              ERR_B64=$(echo "$STATUS_RESPONSE" | ${pkgs.jq}/bin/jq -r '.return."err-data" // empty' 2>/dev/null)
              if [ -n "$ERR_B64" ]; then
                echo "ERROR: $(echo "$ERR_B64" | ${pkgs.coreutils}/bin/base64 -d 2>/dev/null)"
              fi
              echo "ERROR: Failed to append configuration (exit code $EXIT_CODE)"
              exit 1
            fi

            echo "Configuration added. Restarting Home Assistant Core..."

            # Restart HA Core to apply changes
            EXEC_RESPONSE=$({ echo '{"execute":"guest-exec","arguments":{"path":"/usr/bin/ha","arg":["core","restart"],"capture-output":true}}'; sleep 2; } | \
              timeout 10 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null | head -1)

            PID=$(echo "$EXEC_RESPONSE" | ${pkgs.jq}/bin/jq -r '.return.pid // empty' 2>/dev/null)
            if [ -n "$PID" ]; then
              # Wait for restart command to complete
              for i in $(seq 1 30); do
                sleep 2
                STATUS_RESPONSE=$({ echo "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$PID}}"; sleep 1; } | \
                  timeout 8 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null | head -1)

                EXITED=$(echo "$STATUS_RESPONSE" | ${pkgs.jq}/bin/jq -r '.return.exited // false' 2>/dev/null)
                if [ "$EXITED" = "true" ]; then
                  break
                fi
              done
            fi

            echo "Reverse proxy configuration complete"
    '';
  };
}
