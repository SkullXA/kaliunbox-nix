{
  config,
  pkgs,
  lib,
  ...
}: let
  updateScript = pkgs.writeScriptBin "kaliun-auto-update" ''
        #!${pkgs.bash}/bin/bash
        set -euo pipefail

        FLAKE_DIR="/etc/nixos/kaliunbox-flake"
        STATE_DIR="/var/lib/kaliun"
        LAST_CHECK_FILE="$STATE_DIR/last_update_check"
        LAST_REBUILD_FILE="$STATE_DIR/last_rebuild"
        LOCK_FILE="$STATE_DIR/auto-update.lock"
        WATCHDOG_PAUSE_FILE="$STATE_DIR/network_watchdog_paused"

        mkdir -p "$STATE_DIR"

        # Pause network watchdog during update (cleanup on exit)
        cleanup_watchdog_pause() {
          rm -f "$WATCHDOG_PAUSE_FILE"
        }
        trap cleanup_watchdog_pause EXIT
        touch "$WATCHDOG_PAUSE_FILE"

        echo "=== Starting KaliunBox Auto-Update ==="

        # Check if another nixos-rebuild is already in progress
        if ${pkgs.systemd}/bin/systemctl is-active --quiet nixos-rebuild-switch-to-configuration.service 2>/dev/null; then
          echo "A nixos-rebuild switch is already in progress, skipping..."
          exit 0
        fi

        # Reset any stale failed units from previous runs
        ${pkgs.systemd}/bin/systemctl reset-failed nixos-rebuild-switch-to-configuration.service 2>/dev/null || true

        # Lock timeout in seconds (30 minutes)
        LOCK_TIMEOUT=1800

        # Use a lock file to prevent concurrent auto-update runs
        exec 200>"$LOCK_FILE"
        if ! ${pkgs.flock}/bin/flock -n 200; then
          # Lock is held - check if it's stale (process crashed without releasing)
          LOCK_TIME=$(cat "$LOCK_FILE" 2>/dev/null || echo "0")
          CURRENT_TIME=$(${pkgs.coreutils}/bin/date +%s)
          LOCK_AGE=$((CURRENT_TIME - LOCK_TIME))

          if [ "$LOCK_AGE" -gt "$LOCK_TIMEOUT" ]; then
            # Lock is old but still held - this shouldn't happen normally
            # The process holding it may be stuck, but we can't safely break the lock
            # Just log and exit; manual intervention may be needed
            echo "Lock held for $LOCK_AGE seconds (> $LOCK_TIMEOUT). Another process may be stuck."
            echo "If no auto-update is running, manually remove: $LOCK_FILE"
          else
            echo "Another auto-update is already running (lock age: $LOCK_AGE seconds), skipping..."
          fi
          exit 0
        fi

        # Write timestamp to lock file
        ${pkgs.coreutils}/bin/date +%s > "$LOCK_FILE"

        # Skip auto-update if device hasn't been claimed yet
        if [ ! -f "$STATE_DIR/config.json" ]; then
          echo "Device not yet claimed - skipping auto-update"
          exit 0
        fi

        # Check if flake directory exists
        if [ ! -d "$FLAKE_DIR" ]; then
          echo "ERROR: Flake directory not found: $FLAKE_DIR"
          echo "This should have been created during installation"
          echo "failed" > "$LAST_CHECK_FILE"
          exit 1
        fi

        cd "$FLAKE_DIR"

        # Update Git repository (if remote is configured)
        if ${pkgs.git}/bin/git remote get-url origin &>/dev/null; then
          echo "Fetching latest changes from Git..."
          if ! ${pkgs.git}/bin/git fetch origin main; then
            echo "ERROR: Failed to fetch updates from Git"
            echo "fetch_failed" > "$LAST_CHECK_FILE"
            echo "failed" > "$LAST_REBUILD_FILE"
            exit 1
          fi

          # Reset any local changes (the remote is the source of truth)
          echo "Resetting to origin/main..."
          ${pkgs.git}/bin/git reset --hard origin/main
          echo "success" > "$LAST_CHECK_FILE"
        else
          echo "No git remote configured (dev mode?) - skipping pull"
          echo "no_remote" > "$LAST_CHECK_FILE"
        fi

        # Get current generation before update (from system profile, not user profile)
        BEFORE_GEN=$(readlink /nix/var/nix/profiles/system | ${pkgs.gnused}/bin/sed 's/system-\([0-9]*\)-link/\1/')
        echo "Current system generation: $BEFORE_GEN"

        # Note: We don't run 'nix flake update' locally because:
        # 1. The device can't push changes back to GitLab
        # 2. Local flake.lock changes would cause merge conflicts on next pull
        # 3. The repo's flake.lock (managed via CI/CD) is the source of truth

        # Create a live snapshot of the HA VM before updating (for recovery)
        QCOW2_PATH="/var/lib/kaliun/home-assistant.qcow2"
        QMP_SOCK="/var/lib/havm/qmp.sock"
        if [ -f "$QCOW2_PATH" ]; then
          echo "Creating pre-update snapshot of Home Assistant VM..."
          SNAPSHOT_NAME="pre-update-$(${pkgs.coreutils}/bin/date +%Y%m%d%H%M%S)"

          # Check disk space (5GB minimum)
          AVAILABLE=$(${pkgs.coreutils}/bin/df -B1 "$(dirname "$QCOW2_PATH")" | ${pkgs.gawk}/bin/awk 'NR==2 {print $4}')
          MIN_FREE=$((5 * 1024 * 1024 * 1024))

          if [ "$AVAILABLE" -ge "$MIN_FREE" ]; then
            SNAPSHOT_CREATED=false

            # Check if VM is running - if so, use QMP for live snapshot
            if [ -S "$QMP_SOCK" ] && ${pkgs.procps}/bin/pgrep -f "qemu.*homeassistant" > /dev/null 2>&1; then
              echo "VM is running, creating live snapshot via QMP..."
              RESULT=$(echo '{"execute":"qmp_capabilities"}
    {"execute":"human-monitor-command","arguments":{"command-line":"savevm '"$SNAPSHOT_NAME"'"}}' | \
                ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QMP_SOCK" 2>&1)

              if echo "$RESULT" | ${pkgs.gnugrep}/bin/grep -q '"error"'; then
                echo "Warning: Failed to create snapshot via QMP (continuing anyway)"
              else
                echo "Snapshot '$SNAPSHOT_NAME' created successfully (live)"
                SNAPSHOT_CREATED=true
              fi
            else
              # VM is stopped, use qemu-img directly
              echo "VM is stopped, creating snapshot via qemu-img..."
              if ${pkgs.qemu}/bin/qemu-img snapshot -c "$SNAPSHOT_NAME" "$QCOW2_PATH" 2>/dev/null; then
                echo "Snapshot '$SNAPSHOT_NAME' created successfully"
                SNAPSHOT_CREATED=true
              else
                echo "Warning: Failed to create snapshot (continuing anyway)"
              fi
            fi

            # Cleanup old snapshots (keep only 2 most recent)
            if [ "$SNAPSHOT_CREATED" = true ]; then
              # Use --force-share to read snapshot list while VM may be running
              SNAPSHOTS=$(${pkgs.qemu}/bin/qemu-img snapshot -l --force-share "$QCOW2_PATH" 2>/dev/null | \
                ${pkgs.gawk}/bin/awk 'NR>2 && NF>0 {print $2}' | \
                ${pkgs.coreutils}/bin/head -n -2)

              for OLD_SNAP in $SNAPSHOTS; do
                echo "Removing old snapshot: $OLD_SNAP"
                # Use QMP if VM is running, otherwise qemu-img
                if [ -S "$QMP_SOCK" ] && ${pkgs.procps}/bin/pgrep -f "qemu.*homeassistant" > /dev/null 2>&1; then
                  echo '{"execute":"qmp_capabilities"}
    {"execute":"human-monitor-command","arguments":{"command-line":"delvm '"$OLD_SNAP"'"}}' | \
                    ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QMP_SOCK" > /dev/null 2>&1 || true
                else
                  ${pkgs.qemu}/bin/qemu-img snapshot -d "$OLD_SNAP" "$QCOW2_PATH" 2>/dev/null || true
                fi
              done
            fi
          else
            echo "Warning: Insufficient disk space for snapshot (need 5GB free)"
          fi
        fi

        # Build new configuration (will activate on next boot)
        echo "Building new system configuration..."

        # Detect architecture and select appropriate flake target
        ARCH=$(${pkgs.coreutils}/bin/uname -m)
        if [ "$ARCH" = "aarch64" ]; then
          FLAKE_TARGET="kaliunbox-aarch64"
        else
          FLAKE_TARGET="kaliunbox"
        fi
        echo "Detected architecture: $ARCH -> using flake target: $FLAKE_TARGET"

        if /run/current-system/sw/bin/nixos-rebuild switch --flake ".#$FLAKE_TARGET"; then
          AFTER_GEN=$(readlink /nix/var/nix/profiles/system | ${pkgs.gnused}/bin/sed 's/system-\([0-9]*\)-link/\1/')

          if [ "$BEFORE_GEN" != "$AFTER_GEN" ]; then
            echo "System updated successfully to generation $AFTER_GEN"
            echo "Changes have been applied immediately"
            echo "success" > "$LAST_REBUILD_FILE"

            # Reset rollback attempts counter for clean state on next boot
            echo "0" > "$STATE_DIR/rollback_attempts"
          else
            echo "No system changes, still on generation $BEFORE_GEN"
            echo "no_updates" > "$LAST_CHECK_FILE"
            echo "skipped" > "$LAST_REBUILD_FILE"
          fi

          echo "=== Auto-Update Completed Successfully ==="
          exit 0
        else
          echo "ERROR: Failed to build new configuration"
          echo "System remains on generation $BEFORE_GEN"
          echo "No changes have been applied"
          echo "failed" > "$LAST_REBUILD_FILE"

          exit 1
        fi
  '';
in {
  systemd.services = {
    # Auto-update systemd service
    kaliun-auto-update = {
      description = "KaliunBox Auto-Update Service";
      wants = ["network-online.target"];
      after = ["network-online.target"];

      serviceConfig = {
        Type = "oneshot";
        User = "root";

        # Security settings
        PrivateTmp = true;

        # Restart policy
        Restart = "on-failure";
        RestartSec = "5min";
      };

      script = "${updateScript}/bin/kaliun-auto-update";

      # On failure, log and continue
      onFailure = ["kaliun-auto-update-failure.service"];
    };

    # Failure notification service
    kaliun-auto-update-failure = {
      description = "KaliunBox Auto-Update Failure Handler";
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        echo "Auto-update failed!"
        echo "System remains on previous generation"
      '';
    };
  };

  # Timer for periodic updates (every 30 minutes)
  systemd.timers.kaliun-auto-update = {
    description = "KaliunBox Auto-Update Timer";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "30min";
      Unit = "kaliun-auto-update.service";
      Persistent = true;

      # Randomize start time by up to 1 minute to avoid thundering herd
      RandomizedDelaySec = "1min";
    };
  };

  # Ensure flake directory is managed
  system.activationScripts.ensureFlakeDir = ''
    if [ ! -d /etc/nixos/kaliunbox-flake ]; then
      mkdir -p /etc/nixos
      echo "WARNING: KaliunBox flake directory not found"
      echo "Auto-update will not work until installation is complete"
    fi
  '';

  # Add update scripts to system packages
  environment.systemPackages = [
    updateScript
    (pkgs.writeScriptBin "kaliunbox-update" ''
      #!${pkgs.bash}/bin/bash
      echo "Triggering manual system update..."
      ${pkgs.systemd}/bin/systemctl start kaliun-auto-update.service
      echo ""
      echo "Following update log (Ctrl+C to stop):"
      ${pkgs.systemd}/bin/journalctl -u kaliun-auto-update.service -f
    '')

    (pkgs.writeScriptBin "kaliunbox-update-logs" ''
      #!${pkgs.bash}/bin/bash
      ${pkgs.systemd}/bin/journalctl -u kaliun-auto-update.service -f
    '')

    (pkgs.writeScriptBin "kaliunbox-rollback" ''
      #!${pkgs.bash}/bin/bash
      echo "Rolling back to previous system generation..."
      /run/current-system/sw/bin/nixos-rebuild switch --rollback
    '')
  ];
}
