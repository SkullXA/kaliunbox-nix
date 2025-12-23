# Home Assistant proxy setup service
# Configures Home Assistant for reverse proxy support
{
  config,
  pkgs,
  lib,
  ...
}: {
  systemd = {
    # Service to configure HA for reverse proxy support
    # Runs on every boot to ensure config is present (user may remove it)
    services.homeassistant-proxy-setup = {
      description = "Configure Home Assistant for reverse proxy";
      after = ["homeassistant-vm.service"];
      requires = ["homeassistant-vm.service"];
      wantedBy = ["multi-user.target"];

      restartIfChanged = true;

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
                    TRUSTED_PROXY_FILE="/var/lib/havm/trusted_proxy_ip"
                    if echo "$QEMU_ARGS" | ${pkgs.gnugrep}/bin/grep -qE 'netdev (user,|slirp)'; then
                      echo "Detected SLIRP/user-mode networking, using localhost for Home Assistant"
                      HA_IP="127.0.0.1"
                      # In SLIRP mode, get the host's IP - that's where traffic to the VM comes from
                      HOST_IP=$(${pkgs.iproute2}/bin/ip -4 route get 1.1.1.1 2>/dev/null | ${pkgs.gnugrep}/bin/grep -oP 'src \K[\d.]+' | head -1)
                      if [ -n "$HOST_IP" ]; then
                        echo "Host IP: $HOST_IP"
                        TRUSTED_IPS="$HOST_IP"
                      else
                        echo "WARNING: Could not detect host IP, using SLIRP gateway"
                        TRUSTED_IPS="10.0.2.2"
                      fi
                      echo "$TRUSTED_IPS" > "$TRUSTED_PROXY_FILE"
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

                      # Detect host's bridge IP for trusted_proxies (this is where Newt connects from)
                      echo "Detecting host bridge IP for trusted proxies..."
                      HOST_BRIDGE_IP=$(${pkgs.iproute2}/bin/ip -4 addr show br-haos 2>/dev/null | ${pkgs.gnugrep}/bin/grep -oP 'inet \K[\d.]+' | head -1)
                      if [ -n "$HOST_BRIDGE_IP" ]; then
                        echo "Host bridge IP: $HOST_BRIDGE_IP"
                        TRUSTED_IPS="$HOST_BRIDGE_IP 127.0.0.1"
                        echo "$HOST_BRIDGE_IP" > "$TRUSTED_PROXY_FILE"
                      else
                        echo "WARNING: Could not detect br-haos IP, using localhost only"
                        TRUSTED_IPS="127.0.0.1"
                        echo "127.0.0.1" > "$TRUSTED_PROXY_FILE"
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

                    # Build the expected trusted_proxies list for comparison
                    EXPECTED_PROXIES=""
                    for ip in $TRUSTED_IPS; do
                      EXPECTED_PROXIES="$EXPECTED_PROXIES $ip"
                    done
                    EXPECTED_PROXIES=$(echo "$EXPECTED_PROXIES" | xargs | tr ' ' '\n' | sort | xargs)
                    echo "Expected trusted proxies: $EXPECTED_PROXIES"

                    # Check if config exists and get current trusted_proxies from our managed section
                    CHECK_CMD="if grep -q 'BEGIN KALIUNBOX MANAGED' $HA_CONFIG 2>/dev/null; then sed -n '/BEGIN KALIUNBOX MANAGED/,/END KALIUNBOX MANAGED/p' $HA_CONFIG | grep '^ *- ' | sed 's/.*- //' | sort | xargs; else echo 'MISSING'; fi"

                    CURRENT_PROXIES=""
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
                          RESULT=$(echo "$OUTPUT_B64" | ${pkgs.coreutils}/bin/base64 -d 2>/dev/null | tr -d '\n')
                          echo "Config check result: $RESULT"
                          if [ "$RESULT" = "MISSING" ]; then
                            break
                          else
                            CONFIG_EXISTS=true
                            CURRENT_PROXIES="$RESULT"
                            break
                          fi
                        fi
                      fi
                      echo "Config check attempt $check_attempt failed, retrying..."
                      sleep 3
                    done

                    if [ "$CONFIG_EXISTS" = "true" ]; then
                      echo "Current trusted proxies: $CURRENT_PROXIES"
                      if [ "$CURRENT_PROXIES" = "$EXPECTED_PROXIES" ]; then
                        echo "HTTP configuration already exists with correct trusted proxies"
                        exit 0
                      else
                        echo "Trusted proxies mismatch - updating configuration..."
                        # Remove existing MANAGED BY KALIUNBOX section using unique markers
                        REMOVE_CMD="sed -i '/^ *# BEGIN KALIUNBOX MANAGED/,/^ *# END KALIUNBOX MANAGED/d' $HA_CONFIG && sed -i '/^$/N;/^\n$/d' $HA_CONFIG"

                        EXEC_JSON=$(${pkgs.jq}/bin/jq -n --arg cmd "$REMOVE_CMD" '{
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
                        if [ -n "$PID" ]; then
                          sleep 2
                          { echo "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$PID}}"; sleep 1; } | \
                            timeout 8 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null >/dev/null
                        fi
                        echo "Removed old HTTP configuration"
                      fi
                    fi

                    # Add reverse proxy configuration to HA
                    echo "Adding reverse proxy configuration to Home Assistant..."
                    echo "Trusted proxy IPs: $TRUSTED_IPS"

                    # Generate trusted_proxies YAML dynamically based on detected IPs
                    PROXY_LINES=""
                    for ip in $TRUSTED_IPS; do
                      PROXY_LINES="$PROXY_LINES
            - $ip"
                    done

                    # The configuration to append (base64 encoded to safely pass through JSON)
                    HTTP_CONFIG_B64=$(${pkgs.coreutils}/bin/base64 -w0 << CONFIGEOF

        # BEGIN KALIUNBOX MANAGED PROXY CONFIG - DO NOT EDIT
        http:
          use_x_forwarded_for: true
          trusted_proxies:$PROXY_LINES
        # END KALIUNBOX MANAGED PROXY CONFIG
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

    # Monitor service to detect and handle IP changes (DHCP lease renewals)
    services.homeassistant-proxy-monitor = {
      description = "Monitor and update Home Assistant trusted proxies on IP change";
      after = ["homeassistant-proxy-setup.service"];
      requires = ["homeassistant-vm.service"];

      serviceConfig = {
        Type = "oneshot";
      };

      script = ''
              set -euo pipefail

              TRUSTED_PROXY_FILE="/var/lib/havm/trusted_proxy_ip"

              # Detect current IP based on networking mode
              # Check if QEMU is using SLIRP (user-mode networking)
              QEMU_ARGS=$(${pkgs.procps}/bin/ps aux | ${pkgs.gnugrep}/bin/grep -E 'qemu.*homeassistant' | ${pkgs.gnugrep}/bin/grep -v grep | head -1)
              if echo "$QEMU_ARGS" | ${pkgs.gnugrep}/bin/grep -qE 'netdev (user,|slirp)'; then
                # SLIRP mode - get host's outbound IP
                CURRENT_IP=$(${pkgs.iproute2}/bin/ip -4 route get 1.1.1.1 2>/dev/null | ${pkgs.gnugrep}/bin/grep -oP 'src \K[\d.]+' | head -1)
              else
                # Bridge mode - get br-haos IP
                CURRENT_IP=$(${pkgs.iproute2}/bin/ip -4 addr show br-haos 2>/dev/null | ${pkgs.gnugrep}/bin/grep -oP 'inet \K[\d.]+' | head -1)
              fi

              if [ -z "$CURRENT_IP" ]; then
                echo "Could not detect current IP"
                exit 0
              fi

              # Check if IP has changed
              SAVED_IP=""
              if [ -f "$TRUSTED_PROXY_FILE" ]; then
                SAVED_IP=$(cat "$TRUSTED_PROXY_FILE")
              fi

              if [ "$CURRENT_IP" = "$SAVED_IP" ]; then
                echo "IP unchanged: $CURRENT_IP"
                exit 0
              fi

              echo "IP changed from '$SAVED_IP' to '$CURRENT_IP' - updating trusted_proxies..."

              QGA_SOCK="/var/lib/havm/qga.sock"
              HA_CONFIG="/mnt/data/supervisor/homeassistant/configuration.yaml"

              # Wait for guest agent to be ready
              for i in $(seq 1 10); do
                PING=$({ echo '{"execute":"guest-ping"}'; sleep 1; } | \
                  timeout 5 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null | head -1)
                if echo "$PING" | ${pkgs.jq}/bin/jq -e '.return' >/dev/null 2>&1; then
                  break
                fi
                sleep 3
              done

              # Remove old MANAGED BY KALIUNBOX section using unique markers
              REMOVE_CMD="sed -i '/^ *# BEGIN KALIUNBOX MANAGED/,/^ *# END KALIUNBOX MANAGED/d' $HA_CONFIG && sed -i '/^$/N;/^\n$/d' $HA_CONFIG"

              # Execute removal via guest agent
              EXEC_JSON=$(${pkgs.jq}/bin/jq -n --arg cmd "$REMOVE_CMD" '{
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
              if [ -n "$PID" ]; then
                sleep 2
                { echo "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$PID}}"; sleep 1; } | \
                  timeout 8 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null >/dev/null
              fi

              # Generate new config with current IP
              # SLIRP mode uses only the host IP; bridge mode adds localhost
              if echo "$QEMU_ARGS" | ${pkgs.gnugrep}/bin/grep -qE 'netdev (user,|slirp)'; then
                TRUSTED_IPS="$CURRENT_IP"
              else
                TRUSTED_IPS="$CURRENT_IP 127.0.0.1"
              fi
              PROXY_LINES=""
              for ip in $TRUSTED_IPS; do
                PROXY_LINES="$PROXY_LINES
            - $ip"
              done

              HTTP_CONFIG_B64=$(${pkgs.coreutils}/bin/base64 -w0 << CONFIGEOF

        # BEGIN KALIUNBOX MANAGED PROXY CONFIG - DO NOT EDIT
        http:
          use_x_forwarded_for: true
          trusted_proxies:$PROXY_LINES
        # END KALIUNBOX MANAGED PROXY CONFIG
        CONFIGEOF
        )

              APPEND_CMD="echo $HTTP_CONFIG_B64 | base64 -d >> $HA_CONFIG"

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
              if [ -n "$PID" ]; then
                sleep 2
                STATUS_RESPONSE=$({ echo "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$PID}}"; sleep 1; } | \
                  timeout 8 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null | head -1)

                EXIT_CODE=$(echo "$STATUS_RESPONSE" | ${pkgs.jq}/bin/jq -r '.return.exitcode // 1' 2>/dev/null)
                if [ "$EXIT_CODE" != "0" ]; then
                  echo "ERROR: Failed to append new configuration"
                  exit 1
                fi
              fi

              # Update saved IP
              echo "$CURRENT_IP" > "$TRUSTED_PROXY_FILE"

              # Restart HA Core to apply changes
              echo "Restarting Home Assistant Core..."
              { echo '{"execute":"guest-exec","arguments":{"path":"/usr/bin/ha","arg":["core","restart"],"capture-output":true}}'; sleep 2; } | \
                timeout 10 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null >/dev/null

              echo "Trusted proxies updated to: $TRUSTED_IPS"
      '';
    };

    # Timer to run the monitor every 5 minutes
    timers.homeassistant-proxy-monitor = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "5min";
        Unit = "homeassistant-proxy-monitor.service";
      };
    };
  };
}
