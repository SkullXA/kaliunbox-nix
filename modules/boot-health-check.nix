# Boot Health Check with Auto-Rollback
# Validates new NixOS generations after boot and rolls back if unhealthy
{
  config,
  pkgs,
  lib,
  ...
}: let
  bootHealthScript = pkgs.writeScriptBin "kaliunbox-boot-health" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    STATE_DIR="/var/lib/kaliun"
    KNOWN_GOOD_FILE="$STATE_DIR/known_good_generation"
    BOOT_STATUS_FILE="$STATE_DIR/boot_health_status"
    ROLLBACK_ATTEMPTS_FILE="$STATE_DIR/rollback_attempts"

    MAX_ROLLBACK_ATTEMPTS=2
    HEALTH_CHECK_RETRIES=3
    HEALTH_CHECK_INTERVAL=120

    mkdir -p "$STATE_DIR"

    echo "=== KaliunBox Boot Health Check ==="

    # Get current generation
    CURRENT_GEN=$(readlink /nix/var/nix/profiles/system | ${pkgs.gnused}/bin/sed 's/system-\([0-9]*\)-link/\1/')
    echo "Current generation: $CURRENT_GEN"

    # Get known good generation
    KNOWN_GOOD=$(cat "$KNOWN_GOOD_FILE" 2>/dev/null || echo "")
    echo "Known good generation: ''${KNOWN_GOOD:-none}"

    # If no known good generation, set current as known good and exit
    if [ -z "$KNOWN_GOOD" ]; then
      echo "No known good generation recorded, setting current as baseline"
      echo "$CURRENT_GEN" > "$KNOWN_GOOD_FILE"
      echo "healthy" > "$BOOT_STATUS_FILE"
      echo "0" > "$ROLLBACK_ATTEMPTS_FILE"
      exit 0
    fi

    # If current equals known good, we're already on a good generation
    if [ "$CURRENT_GEN" = "$KNOWN_GOOD" ]; then
      echo "Already on known good generation"
      echo "healthy" > "$BOOT_STATUS_FILE"
      echo "0" > "$ROLLBACK_ATTEMPTS_FILE"
      exit 0
    fi

    # New generation - perform health checks
    echo "New generation detected, performing health checks..."

    # Wait for system to stabilize
    echo "Waiting 5 minutes for system to stabilize..."
    sleep 300

    perform_health_check() {
      local check_num=$1
      echo "Health check $check_num/$HEALTH_CHECK_RETRIES..."

      /run/current-system/sw/bin/havm-health-check
      local health_status=$?

      case $health_status in
        0)
          echo "  OK: HA VM healthy and responding"
          ;;
        1)
          echo "  FAIL: HA not responding (VM is running)"
          return 1
          ;;
        2)
          echo "  FAIL: QEMU process not running"
          return 1
          ;;
        3)
          echo "  FAIL: homeassistant-vm.service not active"
          return 1
          ;;
      esac

      # Additional check: No critical failed units (allow some transient failures)
      local FAILED_COUNT
      FAILED_COUNT=$(${pkgs.systemd}/bin/systemctl --failed --no-legend 2>/dev/null | ${pkgs.coreutils}/bin/wc -l || echo "0")
      if [ "$FAILED_COUNT" -gt 3 ]; then
        echo "  FAIL: $FAILED_COUNT failed systemd units"
        return 1
      fi
      echo "  OK: $FAILED_COUNT failed units (threshold: 3)"

      return 0
    }

    # Perform health checks with retries
    HEALTHY=false
    for i in $(seq 1 $HEALTH_CHECK_RETRIES); do
      if perform_health_check "$i"; then
        HEALTHY=true
        break
      fi

      if [ "$i" -lt "$HEALTH_CHECK_RETRIES" ]; then
        echo "Waiting $HEALTH_CHECK_INTERVAL seconds before next check..."
        sleep $HEALTH_CHECK_INTERVAL
      fi
    done

    if [ "$HEALTHY" = "true" ]; then
      echo "All health checks passed"
      echo "healthy" > "$BOOT_STATUS_FILE"
      exit 0
    fi

    # Health checks failed - consider rollback
    echo "Health checks FAILED after $HEALTH_CHECK_RETRIES attempts"
    echo "unhealthy" > "$BOOT_STATUS_FILE"

    ROLLBACK_ATTEMPTS=$(cat "$ROLLBACK_ATTEMPTS_FILE" 2>/dev/null || echo "0")
    NEW_ATTEMPTS=$((ROLLBACK_ATTEMPTS + 1))
    echo "$NEW_ATTEMPTS" > "$ROLLBACK_ATTEMPTS_FILE"

    echo "Rollback attempt $NEW_ATTEMPTS/$MAX_ROLLBACK_ATTEMPTS"

    if [ "$NEW_ATTEMPTS" -gt "$MAX_ROLLBACK_ATTEMPTS" ]; then
      echo "Max rollback attempts reached, staying on current generation"
      echo "Manual intervention required"
      exit 1
    fi

    # Trigger rollback by switching to previous generation
    echo "Triggering rollback to previous generation..."
    PREV_GEN=$((CURRENT_GEN - 1))
    /nix/var/nix/profiles/system-$PREV_GEN-link/bin/switch-to-configuration switch

    echo "Rollback complete, system is now on generation $PREV_GEN"
  '';

  markGoodScript = pkgs.writeScriptBin "kaliunbox-mark-good" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    STATE_DIR="/var/lib/kaliun"
    KNOWN_GOOD_FILE="$STATE_DIR/known_good_generation"
    BOOT_STATUS_FILE="$STATE_DIR/boot_health_status"
    ROLLBACK_ATTEMPTS_FILE="$STATE_DIR/rollback_attempts"

    # Check current health status
    BOOT_STATUS=$(cat "$BOOT_STATUS_FILE" 2>/dev/null || echo "unknown")

    if [ "$BOOT_STATUS" != "healthy" ]; then
      echo "Boot status is '$BOOT_STATUS', not marking as known good"
      exit 0
    fi

    # Get current generation
    CURRENT_GEN=$(readlink /nix/var/nix/profiles/system | ${pkgs.gnused}/bin/sed 's/system-\([0-9]*\)-link/\1/')

    # Mark as known good
    echo "Marking generation $CURRENT_GEN as known good"
    echo "$CURRENT_GEN" > "$KNOWN_GOOD_FILE"
    echo "0" > "$ROLLBACK_ATTEMPTS_FILE"
  '';
in {
  environment.systemPackages = [bootHealthScript markGoodScript];

  systemd = {
    services = {
      kaliunbox-boot-health = {
        description = "KaliunBox Boot Health Check";
        after = ["multi-user.target" "homeassistant-vm.service"];
        wants = ["homeassistant-vm.service"];

        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${bootHealthScript}/bin/kaliunbox-boot-health";
          RemainAfterExit = true;
        };

        wantedBy = ["multi-user.target"];
      };

      kaliunbox-mark-good = {
        description = "Mark current NixOS generation as known good";
        after = ["kaliunbox-boot-health.service"];
        requires = ["kaliunbox-boot-health.service"];

        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${markGoodScript}/bin/kaliunbox-mark-good";
        };
      };
    };

    timers.kaliunbox-mark-good = {
      description = "Timer to mark generation as known good after stable boot";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "15min";
        Unit = "kaliunbox-mark-good.service";
      };
    };
  };
}
