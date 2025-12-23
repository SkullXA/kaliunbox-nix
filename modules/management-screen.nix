{
  config,
  pkgs,
  lib,
  ...
}: let
  kaliunLib = import ./lib.nix {inherit pkgs;};
  inherit (kaliunLib) havmMacScript;

  configFile = "/var/lib/kaliun/config.json";

  statusScript = pkgs.writeScriptBin "kaliun-status" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    # Configuration
    CONFIG_FILE="/var/lib/kaliun/config.json"
    CONNECT_API_URL=$(cat /var/lib/kaliun/connect_api_url 2>/dev/null || echo "https://kaliun-connect-api-production.up.railway.app")
    INSTALL_ID=$(cat /var/lib/kaliun/install_id 2>/dev/null || echo "unknown")

    # Colors
    RESET='\033[0m'
    BOLD='\033[1m'
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'

    # Gather all data first (before clearing screen to avoid blackout)
    # Get system info
    UPTIME=$(${pkgs.coreutils}/bin/uptime | ${pkgs.gnused}/bin/sed 's/.*up //' | ${pkgs.gnused}/bin/sed 's/,.*load.*//' | ${pkgs.coreutils}/bin/tr -d '\n' | ${pkgs.gnused}/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    LOAD=$(${pkgs.coreutils}/bin/uptime | ${pkgs.gawk}/bin/awk -F'load average:' '{print $2}' | ${pkgs.gnused}/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    MEM_USED=$(${pkgs.procps}/bin/free -h | ${pkgs.gawk}/bin/awk '/^Mem:/ {print $3}')
    MEM_TOTAL=$(${pkgs.procps}/bin/free -h | ${pkgs.gawk}/bin/awk '/^Mem:/ {print $2}')
    PRIMARY_IP=$(${pkgs.iproute2}/bin/ip route get 1.1.1.1 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $7; exit}' || echo "No connection")

    # Get HA status and version info from cache
    HA_STATUS="''${RED}●''${RESET} Stopped"
    HA_IP=""
    HA_URL=""
    HA_VERSION=""
    HAOS_VERSION=""
    HA_ARCH=""
    if ${pkgs.systemd}/bin/systemctl is-active --quiet homeassistant-vm.service; then
      # Read cached HA info if available
      if [ -f /var/lib/havm/ha-info.json ]; then
        HA_VERSION=$(${pkgs.jq}/bin/jq -r '.data.homeassistant // empty' /var/lib/havm/ha-info.json 2>/dev/null)
        HAOS_VERSION=$(${pkgs.jq}/bin/jq -r '.data.hassos // empty' /var/lib/havm/ha-info.json 2>/dev/null)
        HA_ARCH=$(${pkgs.jq}/bin/jq -r '.data.arch // empty' /var/lib/havm/ha-info.json 2>/dev/null)
      fi

      # Check network mode
      if [ -f /var/lib/havm/network_mode ] && [ "$(cat /var/lib/havm/network_mode)" = "usermode" ]; then
        # User-mode networking - accessible via host IP
        HA_IP="$PRIMARY_IP (port 8123)"
        HA_URL="http://$PRIMARY_IP:8123"
        if ${pkgs.curl}/bin/curl -s -m 3 "http://127.0.0.1:8123/manifest.json" >/dev/null 2>&1; then
          HA_STATUS="''${GREEN}●''${RESET} Online"
        else
          HA_STATUS="''${YELLOW}●''${RESET} Starting..."
        fi
      else
        # Bridge networking - VM has its own IP
        HAVM_MAC=$(${havmMacScript})
        HA_IP=$(${pkgs.iproute2}/bin/ip neigh show | ${pkgs.gawk}/bin/awk -v mac="$HAVM_MAC" 'BEGIN{IGNORECASE=1} tolower($5)==tolower(mac) {print $1; exit}')

        if [ -z "$HA_IP" ]; then
          GATEWAY=$(${pkgs.iproute2}/bin/ip route | ${pkgs.gawk}/bin/awk '/default/ {print $3; exit}')
          if [ -n "$GATEWAY" ]; then
            NETWORK=$(echo "$GATEWAY" | ${pkgs.gnused}/bin/sed 's/\.[0-9]*$/.0\/24/')
            HA_IP=$(${pkgs.nmap}/bin/nmap -sn -n "$NETWORK" 2>/dev/null | \
                    ${pkgs.gawk}/bin/awk -v mac="$HAVM_MAC" 'BEGIN{IGNORECASE=1} /Nmap scan report/{ip=$NF; gsub(/[()]/,"",ip)} tolower($0)~tolower(mac){print ip; exit}')
          fi
        fi

        if [ -n "$HA_IP" ]; then
          HA_URL="http://$HA_IP:8123"
          if ${pkgs.curl}/bin/curl -s -m 3 "$HA_URL/manifest.json" >/dev/null 2>&1; then
            HA_STATUS="''${GREEN}●''${RESET} Online"
          else
            HA_STATUS="''${YELLOW}●''${RESET} Starting..."
          fi
        else
          HA_STATUS="''${YELLOW}●''${RESET} Waiting..."
        fi
      fi
    fi

    # Get Newt status
    NEWT_STATUS="''${YELLOW}⚠''${RESET} Not configured"
    if [ -f "$CONFIG_FILE" ]; then
      if ${pkgs.systemd}/bin/systemctl is-active --quiet container@newt-agent.service; then
        if ${pkgs.nixos-container}/bin/nixos-container run newt-agent -- test -f /var/lib/newt/health 2>/dev/null; then
          NEWT_STATUS="''${GREEN}●''${RESET} Available"
        elif ${pkgs.nixos-container}/bin/nixos-container run newt-agent -- systemctl is-failed --quiet newt-agent.service 2>/dev/null; then
          NEWT_STATUS="''${RED}●''${RESET} Failed"
        else
          NEWT_STATUS="''${YELLOW}●''${RESET} Starting..."
        fi
      else
        NEWT_STATUS="''${RED}●''${RESET} Stopped"
      fi
    fi

    # Get customer info
    CUSTOMER_NAME="Not configured"
    CUSTOMER_CONTACT="Not configured"
    if [ -f "$CONFIG_FILE" ]; then
      CUSTOMER_NAME=$(${pkgs.jq}/bin/jq -r '.customer.name // "Not configured"' "$CONFIG_FILE")
      CUSTOMER_CONTACT=$(${pkgs.jq}/bin/jq -r '.customer.email // "Unknown"' "$CONFIG_FILE")
    fi

    # Generate QR code (before clearing screen)
    QR_OUTPUT=""
    if [ -f "$CONFIG_FILE" ] && [ "$INSTALL_ID" != "unknown" ]; then
      MGMT_URL="$CONNECT_API_URL/installations/$INSTALL_ID"
      QR_OUTPUT=$(${pkgs.qrencode}/bin/qrencode -t ANSI256 -m 1 -s 1 --level=L "$MGMT_URL" 2>/dev/null || echo "")
    fi

    # Get KaliunBox version from NixOS
    KALIUNBOX_VERSION=$(cat /run/current-system/nixos-version 2>/dev/null || echo "unknown")
    
    # Get flake revision (git commit)
    KALIUN_VERSION=""
    if [ -d /etc/nixos/kaliunbox-flake/.git ]; then
      KALIUN_VERSION=$(cd /etc/nixos/kaliunbox-flake && ${pkgs.git}/bin/git rev-parse --short HEAD 2>/dev/null || echo "")
    fi
    
    # Get last update status
    LAST_UPDATE=""
    if [ -f /var/lib/kaliun/last_rebuild ]; then
      LAST_UPDATE_TS=$(${pkgs.coreutils}/bin/stat -c %Y /var/lib/kaliun/last_rebuild 2>/dev/null)
      if [ -n "$LAST_UPDATE_TS" ]; then
        LAST_UPDATE_TIME=$(${pkgs.coreutils}/bin/date -d "@$LAST_UPDATE_TS" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "")
      fi
      UPDATE_RESULT=$(cat /var/lib/kaliun/last_rebuild 2>/dev/null || echo "")
      if [ "$UPDATE_RESULT" = "success" ]; then
        LAST_UPDATE="$LAST_UPDATE_TIME ''${GREEN}✓''${RESET}"
      elif [ "$UPDATE_RESULT" = "failed" ]; then
        LAST_UPDATE="$LAST_UPDATE_TIME ''${RED}✗''${RESET}"
      elif [ "$UPDATE_RESULT" = "skipped" ]; then
        LAST_UPDATE="$LAST_UPDATE_TIME ''${YELLOW}-''${RESET}"
      fi
    fi

    # Now clear screen and display everything at once
    ${pkgs.ncurses}/bin/tput clear

    # Left side - text content (write all at once)
    {
      echo ""
      echo ""
      echo "  ========================================"
      echo "  KaliunBox Management Console"
      echo "  ========================================"
      echo ""
      echo -e "  ''${BOLD}Customer:''${RESET} $CUSTOMER_NAME"
      echo -e "  ''${BOLD}Contact:''${RESET}  $CUSTOMER_CONTACT"
      echo ""
      echo -e "  ''${BOLD}System:''${RESET}"
      echo "    Uptime:     $UPTIME"
      echo "    Load:       $LOAD"
      echo "    Memory:     $MEM_USED / $MEM_TOTAL"
      echo "    KaliunBox:  $KALIUNBOX_VERSION"
      if [ -n "$KALIUN_VERSION" ]; then
        echo "    Kaliun:     $KALIUN_VERSION"
      fi
      if [ -n "$LAST_UPDATE" ]; then
        echo -e "    Updated:    $LAST_UPDATE"
      fi
      echo ""
      echo -e "  ''${BOLD}Services:''${RESET}"
      echo -e "    Home Assistant:  $HA_STATUS"
      if [ -n "$HA_VERSION" ] && [ -n "$HAOS_VERSION" ]; then
        if [ -n "$HA_ARCH" ]; then
          echo "                     HA $HA_VERSION / HAOS $HAOS_VERSION ($HA_ARCH)"
        else
          echo "                     HA $HA_VERSION / HAOS $HAOS_VERSION"
        fi
      fi
      if [ -n "$HA_URL" ]; then
        echo "                     $HA_URL"
      fi
      echo -e "    Remote Access:   $NEWT_STATUS"
      echo ""
      echo -e "  ''${BOLD}Network:''${RESET}"
      echo "    Host IP:  $PRIMARY_IP"
      echo ""
      echo ""
      echo "  Scan QR code to manage this device"
      echo "  Installation ID: $INSTALL_ID"
      echo ""
    }

    # Right side - QR code positioned at column 60, starting at row 6
    if [ -n "$QR_OUTPUT" ]; then
      row=6
      echo "$QR_OUTPUT" | while IFS= read -r line; do
        printf "\033[''${row};60H%s" "$line"
        row=$((row + 1))
      done
    fi
  '';

  # Loop script that runs the status display continuously
  managementLoopScript = pkgs.writeScriptBin "kaliun-management-loop" ''
    #!${pkgs.bash}/bin/bash

    # Wait for network to be ready before showing status
    # Check both route and actual interface IP for nested VM compatibility
    attempts=0
    while true; do
      # Check if we have any non-loopback IP address
      HAS_IP=$(${pkgs.iproute2}/bin/ip -4 addr show scope global 2>/dev/null | ${pkgs.gnugrep}/bin/grep -c 'inet ' 2>/dev/null || echo "0")
      # Ensure HAS_IP is a valid integer (strip any whitespace/newlines)
      HAS_IP=$(echo "$HAS_IP" | ${pkgs.coreutils}/bin/tr -d '[:space:]')
      [ -z "$HAS_IP" ] && HAS_IP=0
      
      # Also try the route check (works on bare metal)
      HAS_ROUTE=false
      ${pkgs.iproute2}/bin/ip route get 1.1.1.1 &>/dev/null && HAS_ROUTE=true

      if [ "$HAS_IP" -gt 0 ] 2>/dev/null || [ "$HAS_ROUTE" = "true" ]; then
        break
      fi

      printf "\r  Waiting for network... "
      sleep 1
      attempts=$((attempts + 1))
      # Timeout after 60 seconds
      if [ $attempts -ge 60 ]; then
        echo ""
        echo "  Network timeout - proceeding anyway"
        break
      fi
    done

    # Run management screen in an infinite loop
    while true; do
      ${statusScript}/bin/kaliun-status || true
      sleep 30
    done
  '';
in {
  # Always enable management screen (runtime checks handle missing config)
  config = {
    systemd.services = {
      # Disable getty on tty1 - we'll use our own service
      "getty@tty1".enable = false;
      "autovt@tty1".enable = false;

      # Management console service - runs directly on tty1, no shell involved
      management-console = {
        description = "KaliunBox Management Console";
        after = ["systemd-user-sessions.service" "plymouth-quit-wait.service" "getty-pre.target"];
        conflicts = ["getty@tty1.service"];
        wantedBy = ["multi-user.target"];

        serviceConfig = {
          Type = "simple";
          ExecStart = "${managementLoopScript}/bin/kaliun-management-loop";
          StandardInput = "tty";
          StandardOutput = "tty";
          TTYPath = "/dev/tty1";
          TTYReset = true;
          TTYVHangup = true;
          TTYVTDisallocate = true;
          # Restart if it crashes
          Restart = "always";
          RestartSec = "1s";
          # No shell, no user - just the script
          UtmpIdentifier = "tty1";
          UtmpMode = "user";
        };

        # Ensure tty1 is available
        unitConfig = {
          ConditionPathExists = "/dev/tty1";
        };
      };
    };

    # Add status script to system packages (for manual use)
    environment.systemPackages = [statusScript];
  };
}
