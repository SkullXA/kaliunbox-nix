# Network connectivity watchdog
# Monitors external connectivity and triggers rollback if network is lost
# This protects against configuration changes that break network access
{
  config,
  pkgs,
  lib,
  ...
}: let
  # Configuration
  checkInterval = 60; # seconds between checks
  maxFailures = 15; # consecutive failures before rollback (15 minutes)
  rollbackWindow = 1800; # only rollback if generation is younger than 30 minutes
  connectEndpoint = "connect.kaliun.com";
  fallbackEndpoint = "1.1.1.1";

  networkWatchdogScript = pkgs.writeScriptBin "kaliunbox-network-watchdog" ''
    #!${pkgs.bash}/bin/bash
    set -uo pipefail

    STATE_DIR="/var/lib/kaliun"
    FAILURE_COUNT_FILE="$STATE_DIR/network_failure_count"
    PAUSE_FILE="$STATE_DIR/network_watchdog_paused"
    KNOWN_GOOD_FILE="$STATE_DIR/known_good_generation"
    ROLLBACK_ATTEMPTS_FILE="$STATE_DIR/rollback_attempts"
    MAX_ROLLBACK_ATTEMPTS=2

    # Get Connect API URL (with fallback to production)
    CONNECT_API_URL=$(cat "$STATE_DIR/connect_api_url" 2>/dev/null || echo "https://${connectEndpoint}")

    mkdir -p "$STATE_DIR"

    # Initialize failure count if not exists
    if [ ! -f "$FAILURE_COUNT_FILE" ]; then
      echo "0" > "$FAILURE_COUNT_FILE"
    fi

    check_url() {
      # Check connectivity to a full URL
      local url="$1"
      local timeout=10

      if ${pkgs.curl}/bin/curl -s -m "$timeout" -o /dev/null "$url" 2>/dev/null; then
        return 0
      fi

      return 1
    }

    check_ip() {
      # Check connectivity to an IP (HTTPS first, then ping)
      local ip="$1"
      local timeout=10

      # Try HTTPS first (Cloudflare 1.1.1.1 serves HTTPS)
      if ${pkgs.curl}/bin/curl -s -m "$timeout" -o /dev/null "https://$ip" 2>/dev/null; then
        return 0
      fi

      # Fallback to ping
      if ${pkgs.iputils}/bin/ping -c 1 -W "$timeout" "$ip" >/dev/null 2>&1; then
        return 0
      fi

      return 1
    }

    perform_rollback() {
      echo "=== NETWORK WATCHDOG: Triggering rollback ==="

      # Record rollback timestamp for health reporting
      ${pkgs.coreutils}/bin/date +%s > "$STATE_DIR/network_watchdog_last_rollback"

      # Check rollback attempts
      local attempts
      attempts=$(cat "$ROLLBACK_ATTEMPTS_FILE" 2>/dev/null || echo "0")

      if [ "$attempts" -ge "$MAX_ROLLBACK_ATTEMPTS" ]; then
        echo "Max rollback attempts ($MAX_ROLLBACK_ATTEMPTS) reached"
        echo "Manual intervention required"
        return 1
      fi

      # Increment rollback attempts
      echo "$((attempts + 1))" > "$ROLLBACK_ATTEMPTS_FILE"

      # Get current and previous generation
      local current_gen prev_gen
      current_gen=$(readlink /nix/var/nix/profiles/system | ${pkgs.gnused}/bin/sed -E 's|.*/system-([0-9]+)-link|\1|')
      prev_gen=$((current_gen - 1))

      # Check if previous generation exists
      if [ ! -L "/nix/var/nix/profiles/system-$prev_gen-link" ]; then
        echo "Previous generation $prev_gen not found, cannot rollback"
        return 1
      fi

      echo "Rolling back from generation $current_gen to $prev_gen"

      # Switch to previous generation
      /nix/var/nix/profiles/system-$prev_gen-link/bin/switch-to-configuration switch

      # Reboot to fully restore network state
      echo "Rebooting to apply rollback..."
      ${pkgs.systemd}/bin/systemctl reboot
    }

    # Main check loop iteration
    main() {
      # Check if watchdog is paused (during updates)
      if [ -f "$PAUSE_FILE" ]; then
        # Check if pause file is stale (older than 1 hour)
        # This handles cases where system rebooted mid-update
        PAUSE_AGE=$(($(${pkgs.coreutils}/bin/date +%s) - $(${pkgs.coreutils}/bin/stat -c %Y "$PAUSE_FILE")))
        if [ "$PAUSE_AGE" -gt 3600 ]; then
          echo "Stale pause file detected (age: $PAUSE_AGE seconds), removing"
          rm -f "$PAUSE_FILE"
        else
          echo "Watchdog paused (update in progress), skipping check"
          # Reset failure count when paused
          echo "0" > "$FAILURE_COUNT_FILE"
          return 0
        fi
      fi

      # Check if we have a known good generation (device must be set up)
      if [ ! -f "$KNOWN_GOOD_FILE" ]; then
        echo "No known good generation yet, skipping check"
        return 0
      fi

      local connect_status="down"
      local fallback_status="down"

      # Check Connect API (uses configured URL or production default)
      if check_url "$CONNECT_API_URL/health"; then
        connect_status="up"
      fi

      # Check fallback (1.1.1.1)
      if check_ip "${fallbackEndpoint}"; then
        fallback_status="up"
      fi

      # Network is considered UP if at least one endpoint is reachable
      if [ "$connect_status" = "up" ] || [ "$fallback_status" = "up" ]; then
        # Reset failure count on success
        echo "0" > "$FAILURE_COUNT_FILE"
        # Reset rollback attempts when network is stable (allows future rollbacks if needed)
        echo "0" > "$ROLLBACK_ATTEMPTS_FILE"
        echo "Network OK ($CONNECT_API_URL: $connect_status, ${fallbackEndpoint}: $fallback_status)"
        return 0
      fi

      # Both endpoints unreachable - increment failure count
      local failures
      failures=$(cat "$FAILURE_COUNT_FILE" 2>/dev/null || echo "0")
      failures=$((failures + 1))
      echo "$failures" > "$FAILURE_COUNT_FILE"

      echo "Network check FAILED ($failures/${toString maxFailures})"

      # Check if we've exceeded threshold
      if [ "$failures" -ge ${toString maxFailures} ]; then
        echo "Network unreachable for ${toString maxFailures} consecutive checks"

        # Only rollback if the current generation was activated recently
        # This prevents rollback during external network outages (ISP issues)
        GEN_TIMESTAMP=$(${pkgs.coreutils}/bin/stat -c %Y /nix/var/nix/profiles/system)
        CURRENT_TIME=$(${pkgs.coreutils}/bin/date +%s)
        GEN_AGE=$((CURRENT_TIME - GEN_TIMESTAMP))

        if [ "$GEN_AGE" -gt ${toString rollbackWindow} ]; then
          echo "Generation is $GEN_AGE seconds old (>${toString rollbackWindow}s), likely external outage - skipping rollback"
          return 0
        fi

        echo "Generation is $GEN_AGE seconds old, may be config issue - triggering rollback"
        perform_rollback
      fi
    }

    main
  '';
in {
  environment.systemPackages = [networkWatchdogScript];

  systemd.services.kaliunbox-network-watchdog = {
    description = "KaliunBox Network Connectivity Watchdog";
    after = ["network-online.target" "kaliunbox-boot-health.service"];
    wants = ["network-online.target"];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${networkWatchdogScript}/bin/kaliunbox-network-watchdog";
      # Don't restart on failure - the timer handles scheduling
      Restart = "no";
    };
  };

  systemd.timers.kaliunbox-network-watchdog = {
    description = "KaliunBox Network Watchdog Timer";
    wantedBy = ["timers.target"];
    timerConfig = {
      # Start 2 minutes after boot to allow network to stabilize
      OnBootSec = "2min";
      # Run every 60 seconds
      OnUnitActiveSec = "${toString checkInterval}s";
      Unit = "kaliunbox-network-watchdog.service";
    };
  };
}







