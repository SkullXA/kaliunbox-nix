# Home Assistant helper scripts
# CLI tools for managing and interacting with the Home Assistant VM
{
  config,
  pkgs,
  lib,
  ...
}: let
  kaliunLib = import ../lib.nix {inherit pkgs;};
  inherit (kaliunLib) havmMacScript;

  haConfig = import ./config.nix {inherit pkgs;};
in {
  environment.systemPackages = [
    (pkgs.writeScriptBin "homeassistant-status" ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      if systemctl is-active --quiet homeassistant-vm.service; then
        echo "Home Assistant VM: Running"

        HAVM_MAC=$(${havmMacScript})
        echo "VM MAC Address: $HAVM_MAC"

        UPTIME=$(systemctl show homeassistant-vm.service -p ActiveEnterTimestamp --value)
        echo "VM Started: $UPTIME"

        # Check network mode
        if [ -f /var/lib/havm/network_mode ] && [ "$(cat /var/lib/havm/network_mode)" = "usermode" ]; then
          # User-mode networking - Home Assistant is accessible on host IP
          HOST_IP=$(${pkgs.iproute2}/bin/ip route get 1.1.1.1 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $7; exit}' || echo "localhost")
          echo ""
          echo "Network Mode: User-mode (port forwarding)"
          echo "IP Address: $HOST_IP (via host)"
          echo "Web Interface: http://$HOST_IP:8123"

          if ${pkgs.curl}/bin/curl -s -m 5 "http://127.0.0.1:8123/manifest.json" > /dev/null 2>&1; then
            echo "Status: Online"
          else
            echo "Status: Booting..."
          fi
        else
          # Bridge networking - VM has its own IP, host can reach it directly
          IP=$(${pkgs.iproute2}/bin/ip neigh show | ${pkgs.gawk}/bin/awk -v mac="$HAVM_MAC" 'BEGIN{IGNORECASE=1} tolower($5)==tolower(mac) {print $1; exit}')

          if [ -z "$IP" ]; then
            GATEWAY=$(${pkgs.iproute2}/bin/ip route | ${pkgs.gawk}/bin/awk '/default/ {print $3; exit}')
            if [ -n "$GATEWAY" ]; then
              NETWORK=$(echo "$GATEWAY" | ${pkgs.gnused}/bin/sed 's/\.[0-9]*$/.0\/24/')
              IP=$(${pkgs.nmap}/bin/nmap -sn -n "$NETWORK" 2>/dev/null | \
                   ${pkgs.gawk}/bin/awk -v mac="$HAVM_MAC" 'BEGIN{IGNORECASE=1} /Nmap scan report/{ip=$NF; gsub(/[()]/,"",ip)} tolower($0)~tolower(mac){print ip; exit}')
            fi
          fi

          echo ""
          echo "Network Mode: Bridge (direct)"
          if [ -n "$IP" ]; then
            echo "IP Address: $IP"
            echo "Web Interface: http://$IP:8123"

            if ${pkgs.curl}/bin/curl -s -m 5 "http://$IP:8123/manifest.json" > /dev/null 2>&1; then
              echo "Status: Online"
            else
              echo "Status: Booting..."
            fi
          else
            echo "IP Address: Not assigned yet (VM may still be booting)"
            echo "Home Assistant OS typically takes 2-3 minutes to boot"
          fi
        fi
      else
        echo "Home Assistant VM: Stopped"
      fi
    '')

    (pkgs.writeScriptBin "homeassistant-console" ''
      #!${pkgs.bash}/bin/bash
      echo "Home Assistant OS Console Access"
      echo "================================"
      echo ""
      echo "CLI Access via QEMU Guest Agent:"
      echo "  ha info              - Show system info"
      echo "  ha core info         - Show Home Assistant Core info"
      echo "  ha supervisor info   - Show Supervisor info"
      echo "  ha host reboot       - Reboot HAOS"
      echo ""
      ${
        if haConfig.isAarch64
        then ''
          echo "Serial Console:"
          echo "  Press Enter below to connect."
          echo "  Press Ctrl+O to exit the console."
          echo ""
          read -p "Press Enter to connect to serial console..."
          exec ${pkgs.socat}/bin/socat -,raw,echo=0,escape=0x0f UNIX-CONNECT:/var/lib/havm/console.sock
        ''
        else ''
          echo "VNC Console (graphical):"
          echo "  From another machine: ssh -L 5900:localhost:5900 root@<kaliunbox-ip>"
          echo "  Then connect VNC client to localhost:5900"
        ''
      }
    '')

    (pkgs.writeScriptBin "ha" ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      QGA_SOCK="/var/lib/havm/qga.sock"

      if [ ! -S "$QGA_SOCK" ]; then
        echo "Error: QEMU Guest Agent socket not found. Is the Home Assistant VM running?" >&2
        exit 1
      fi

      # Build JSON array of arguments
      ARGS_JSON="["
      first=true
      for arg in "$@"; do
        if [ "$first" = true ]; then
          first=false
        else
          ARGS_JSON+=","
        fi
        # Escape quotes in argument
        escaped_arg=$(echo "$arg" | ${pkgs.gnused}/bin/sed 's/\\/\\\\/g; s/"/\\"/g')
        ARGS_JSON+="\"$escaped_arg\""
      done
      ARGS_JSON+="]"

      # First check if guest agent is responding
      PING_RESPONSE=$({ echo '{"execute":"guest-ping"}'; sleep 2; } | \
        timeout 5 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null | head -1)

      if [ -z "$PING_RESPONSE" ] || ! echo "$PING_RESPONSE" | ${pkgs.jq}/bin/jq -e '.return' >/dev/null 2>&1; then
        echo "Error: QEMU Guest Agent is not responding." >&2
        echo "The VM may still be booting. Please wait and try again." >&2
        exit 1
      fi

      # Execute command via guest agent
      EXEC_RESPONSE=$({ echo "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"/usr/bin/ha\",\"arg\":$ARGS_JSON,\"capture-output\":true}}"; sleep 2; } | \
        timeout 10 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null | head -1)

      PID=$(echo "$EXEC_RESPONSE" | ${pkgs.jq}/bin/jq -r '.return.pid // empty' 2>/dev/null)

      if [ -z "$PID" ]; then
        ERROR=$(echo "$EXEC_RESPONSE" | ${pkgs.jq}/bin/jq -r '.error.desc // empty' 2>/dev/null)
        if [ -n "$ERROR" ]; then
          echo "Guest agent error: $ERROR" >&2
        else
          echo "Failed to execute command via guest agent" >&2
        fi
        exit 1
      fi

      # Poll for completion (up to 60 seconds for long-running commands)
      for i in $(seq 1 60); do
        STATUS_RESPONSE=$({ echo "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$PID}}"; sleep 1; } | \
          timeout 5 ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QGA_SOCK" 2>/dev/null | head -1)

        EXITED=$(echo "$STATUS_RESPONSE" | ${pkgs.jq}/bin/jq -r '.return.exited // false' 2>/dev/null)

        if [ "$EXITED" = "true" ]; then
          # Get stdout (base64 decoded)
          OUTPUT_B64=$(echo "$STATUS_RESPONSE" | ${pkgs.jq}/bin/jq -r '.return."out-data" // empty' 2>/dev/null)
          if [ -n "$OUTPUT_B64" ]; then
            echo "$OUTPUT_B64" | ${pkgs.coreutils}/bin/base64 -d 2>/dev/null
          fi

          # Get stderr (base64 decoded)
          ERR_B64=$(echo "$STATUS_RESPONSE" | ${pkgs.jq}/bin/jq -r '.return."err-data" // empty' 2>/dev/null)
          if [ -n "$ERR_B64" ]; then
            echo "$ERR_B64" | ${pkgs.coreutils}/bin/base64 -d >&2 2>/dev/null
          fi

          # Return exit code
          EXIT_CODE=$(echo "$STATUS_RESPONSE" | ${pkgs.jq}/bin/jq -r '.return.exitcode // 0' 2>/dev/null)
          exit "$EXIT_CODE"
        fi
        sleep 1
      done

      echo "Command timed out" >&2
      exit 1
    '')
  ];
}
