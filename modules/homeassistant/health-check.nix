# Shared health check for Home Assistant VM
# Used by both watchdog and boot-health-check for consistent health monitoring
{
  config,
  pkgs,
  lib,
  ...
}: let
  healthCheckScript = pkgs.writeScriptBin "havm-health-check" ''
    #!${pkgs.bash}/bin/bash
    set -uo pipefail

    # Exit codes:
    #   0 = healthy (HA responding)
    #   1 = HA not responding but VM running
    #   2 = VM not running (QEMU process dead)
    #   3 = VM service not active

    STATE_DIR="/var/lib/havm"

    # Check if VM service is active
    if ! ${pkgs.systemd}/bin/systemctl is-active --quiet homeassistant-vm.service; then
      echo "VM service is not active"
      exit 3
    fi

    # Check if QEMU process is running
    if ! ${pkgs.procps}/bin/pgrep -f "qemu.*homeassistant" > /dev/null 2>&1; then
      echo "QEMU process not running"
      exit 2
    fi

    # Determine the correct endpoint based on network mode
    if [ -f "$STATE_DIR/network_mode" ]; then
      MODE=$(cat "$STATE_DIR/network_mode")
      case "$MODE" in
        usermode)
          HA_URL="http://127.0.0.1:8123"
          ;;
        bridge|*)
          # In bridge mode, find the VM's IP from ARP table on br-haos
          if [ -f "$STATE_DIR/mac_address" ]; then
            VM_MAC=$(cat "$STATE_DIR/mac_address")
            VM_IP=$(${pkgs.iproute2}/bin/ip neigh show dev br-haos 2>/dev/null | ${pkgs.gnugrep}/bin/grep -i "$VM_MAC" | ${pkgs.gnugrep}/bin/grep -v FAILED | ${pkgs.gawk}/bin/awk '{print $1}' | head -1)
            if [ -n "$VM_IP" ]; then
              HA_URL="http://$VM_IP:8123"
            else
              # Fallback to localhost (will likely fail in bridge mode, but better than nothing)
              HA_URL="http://localhost:8123"
            fi
          else
            HA_URL="http://localhost:8123"
          fi
          ;;
      esac
    else
      HA_URL="http://localhost:8123"
    fi

    # Log which URL we're checking (useful for debugging)
    echo "Checking $HA_URL"

    # Perform HTTP health check
    HTTP_CODE=$(${pkgs.curl}/bin/curl -s -m 10 -o /dev/null -w "%{http_code}" "$HA_URL/" 2>/dev/null || echo "000")

    # Extract only the last 3 characters (the actual HTTP code) in case of redirects
    HTTP_CODE="''${HTTP_CODE: -3}"

    if [ "$HTTP_CODE" != "000" ]; then
      echo "HA is responding (HTTP $HTTP_CODE)"
      exit 0
    fi

    echo "HA not responding (HTTP $HTTP_CODE)"
    exit 1
  '';
in {
  environment.systemPackages = [healthCheckScript];
}
