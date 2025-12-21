# Home Assistant VM Watchdog
# Monitors the HA VM health and restarts it if unresponsive
# Uses shared havm-health-check script for consistent health monitoring
{
  config,
  pkgs,
  lib,
  ...
}: let
  watchdogScript = pkgs.writeScriptBin "homeassistant-watchdog" ''
    #!${pkgs.bash}/bin/bash
    set -uo pipefail

    STATE_DIR="/var/lib/havm"
    FAILURES_FILE="$STATE_DIR/watchdog_failures"
    LAST_RESTART_FILE="$STATE_DIR/watchdog_last_restart"

    MAX_FAILURES=3
    COOLDOWN_SECONDS=1800

    mkdir -p "$STATE_DIR"

    echo "=== Home Assistant Watchdog Check ==="

    increment_and_maybe_restart() {
      CURRENT_FAILURES=$(cat "$FAILURES_FILE" 2>/dev/null || echo "0")
      NEW_FAILURES=$((CURRENT_FAILURES + 1))
      echo "$NEW_FAILURES" > "$FAILURES_FILE"

      echo "HA not responding (failure $NEW_FAILURES/$MAX_FAILURES)"

      if [ "$NEW_FAILURES" -lt "$MAX_FAILURES" ]; then
        echo "Not enough failures to trigger restart yet"
        return
      fi

      # Check cooldown
      LAST_RESTART=$(cat "$LAST_RESTART_FILE" 2>/dev/null || echo "0")
      NOW=$(${pkgs.coreutils}/bin/date +%s)
      ELAPSED=$((NOW - LAST_RESTART))

      if [ "$ELAPSED" -lt "$COOLDOWN_SECONDS" ]; then
        REMAINING=$((COOLDOWN_SECONDS - ELAPSED))
        echo "Cooldown active: $REMAINING seconds remaining"
        echo "Skipping restart to prevent loops"
        return
      fi

      # Trigger restart
      echo "Triggering VM restart..."
      echo "$NOW" > "$LAST_RESTART_FILE"
      echo "0" > "$FAILURES_FILE"

      ${pkgs.systemd}/bin/systemctl restart homeassistant-vm.service
      echo "VM restart triggered by watchdog"
    }

    /run/current-system/sw/bin/havm-health-check
    HEALTH_STATUS=$?

    case $HEALTH_STATUS in
      0)
        echo "0" > "$FAILURES_FILE"
        ;;
      1)
        # HA not responding but VM running - use threshold
        increment_and_maybe_restart
        ;;
      2)
        # QEMU process died - restart immediately (bypass threshold)
        echo "QEMU process died, restarting immediately"
        NOW=$(${pkgs.coreutils}/bin/date +%s)

        # Still respect cooldown to prevent rapid restart loops
        LAST_RESTART=$(cat "$LAST_RESTART_FILE" 2>/dev/null || echo "0")
        ELAPSED=$((NOW - LAST_RESTART))

        if [ "$ELAPSED" -lt "$COOLDOWN_SECONDS" ]; then
          REMAINING=$((COOLDOWN_SECONDS - ELAPSED))
          echo "Cooldown active: $REMAINING seconds remaining"
          echo "Skipping restart to prevent loops"
        else
          echo "$NOW" > "$LAST_RESTART_FILE"
          echo "0" > "$FAILURES_FILE"
          ${pkgs.systemd}/bin/systemctl restart homeassistant-vm.service
          echo "VM restart triggered by watchdog (QEMU crash)"
        fi
        ;;
      3)
        # VM service not active - skip (handled by systemd)
        echo "0" > "$FAILURES_FILE"
        ;;
    esac
  '';
in {
  environment.systemPackages = [watchdogScript];

  systemd = {
    services.homeassistant-watchdog = {
      description = "Home Assistant VM Watchdog";
      after = ["homeassistant-vm.service"];
      wants = ["homeassistant-vm.service"];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${watchdogScript}/bin/homeassistant-watchdog";
      };
    };

    timers.homeassistant-watchdog = {
      description = "Home Assistant VM Watchdog Timer";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "5min";
        Unit = "homeassistant-watchdog.service";
      };
    };
  };
}
