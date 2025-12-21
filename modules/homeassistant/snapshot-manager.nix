# Home Assistant VM Snapshot Manager
# Provides qcow2 snapshot management for VM state recovery
# Live snapshots use QMP when VM is running, qemu-img when stopped
{
  config,
  pkgs,
  lib,
  ...
}: let
  haConfig = import ./config.nix {inherit pkgs;};

  snapshotCreateScript = pkgs.writeScriptBin "havm-snapshot-create" ''
        #!${pkgs.bash}/bin/bash
        set -euo pipefail

        QCOW2_PATH="${haConfig.haosImagePath}"
        QMP_SOCK="/var/lib/havm/qmp.sock"
        MIN_FREE_BYTES=$((5 * 1024 * 1024 * 1024))  # 5GB minimum

        SNAPSHOT_NAME="''${1:-pre-update-$(${pkgs.coreutils}/bin/date +%Y%m%d%H%M%S)}"

        echo "=== Creating snapshot: $SNAPSHOT_NAME ==="

        # Check disk space
        AVAILABLE=$(${pkgs.coreutils}/bin/df -B1 "$(dirname "$QCOW2_PATH")" | ${pkgs.gawk}/bin/awk 'NR==2 {print $4}')
        if [ "$AVAILABLE" -lt "$MIN_FREE_BYTES" ]; then
          echo "ERROR: Insufficient disk space for snapshot"
          echo "Available: $((AVAILABLE / 1024 / 1024 / 1024))GB, Required: 5GB minimum"
          exit 1
        fi

        # Check if qcow2 exists
        if [ ! -f "$QCOW2_PATH" ]; then
          echo "ERROR: qcow2 file not found: $QCOW2_PATH"
          exit 1
        fi

        # Check if VM is running - if so, use QMP for live snapshot
        if [ -S "$QMP_SOCK" ] && ${pkgs.procps}/bin/pgrep -f "qemu.*homeassistant" > /dev/null 2>&1; then
          echo "VM is running, creating live snapshot via QMP..."
          # QMP human-monitor-command allows us to run HMP commands like savevm
          RESULT=$(echo '{"execute":"qmp_capabilities"}
    {"execute":"human-monitor-command","arguments":{"command-line":"savevm '"$SNAPSHOT_NAME"'"}}' | \
            ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QMP_SOCK" 2>&1)

          # Check for errors in the response
          if echo "$RESULT" | ${pkgs.gnugrep}/bin/grep -q '"error"'; then
            echo "ERROR: Failed to create snapshot via QMP"
            echo "$RESULT"
            exit 1
          fi
          echo "Snapshot '$SNAPSHOT_NAME' created successfully (live)"
        else
          # VM is stopped, use qemu-img directly
          echo "VM is stopped, creating snapshot via qemu-img..."
          if ${pkgs.qemu}/bin/qemu-img snapshot -c "$SNAPSHOT_NAME" "$QCOW2_PATH"; then
            echo "Snapshot '$SNAPSHOT_NAME' created successfully"
          else
            echo "ERROR: Failed to create snapshot"
            exit 1
          fi
        fi

        havm-snapshot-list
  '';

  snapshotListScript = pkgs.writeScriptBin "havm-snapshot-list" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    QCOW2_PATH="${haConfig.haosImagePath}"

    if [ ! -f "$QCOW2_PATH" ]; then
      echo "ERROR: qcow2 file not found: $QCOW2_PATH"
      exit 1
    fi

    echo "=== Home Assistant VM Snapshots ==="
    # Use --force-share to allow reading while VM is running
    ${pkgs.qemu}/bin/qemu-img snapshot -l --force-share "$QCOW2_PATH" || echo "No snapshots found"
  '';

  snapshotRestoreScript = pkgs.writeScriptBin "havm-snapshot-restore" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    QCOW2_PATH="${haConfig.haosImagePath}"

    if [ -z "''${1:-}" ]; then
      echo "Usage: havm-snapshot-restore <snapshot-name>"
      echo ""
      havm-snapshot-list
      exit 1
    fi

    SNAPSHOT_NAME="$1"

    echo "=== Restoring snapshot: $SNAPSHOT_NAME ==="

    # Check if VM is running - restore requires VM to be stopped
    if ${pkgs.systemd}/bin/systemctl is-active --quiet homeassistant-vm.service; then
      echo "ERROR: VM must be stopped before restoring a snapshot"
      echo "Run: sudo systemctl stop homeassistant-vm"
      exit 1
    fi

    # Check if QEMU process is running
    if ${pkgs.procps}/bin/pgrep -f "qemu.*homeassistant" > /dev/null 2>&1; then
      echo "ERROR: QEMU process still running"
      echo "Run: sudo pkill -f 'qemu.*homeassistant'"
      exit 1
    fi

    if [ ! -f "$QCOW2_PATH" ]; then
      echo "ERROR: qcow2 file not found: $QCOW2_PATH"
      exit 1
    fi

    echo "WARNING: This will restore the VM to a previous state."
    echo "All changes since the snapshot will be lost!"
    echo ""
    read -p "Continue? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
      echo "Restore cancelled"
      exit 0
    fi

    echo "Restoring snapshot..."
    if ${pkgs.qemu}/bin/qemu-img snapshot -a "$SNAPSHOT_NAME" "$QCOW2_PATH"; then
      echo "Snapshot '$SNAPSHOT_NAME' restored successfully"
      echo ""
      echo "Start the VM with: sudo systemctl start homeassistant-vm"
    else
      echo "ERROR: Failed to restore snapshot"
      exit 1
    fi
  '';

  snapshotDeleteScript = pkgs.writeScriptBin "havm-snapshot-delete" ''
        #!${pkgs.bash}/bin/bash
        set -euo pipefail

        QCOW2_PATH="${haConfig.haosImagePath}"
        QMP_SOCK="/var/lib/havm/qmp.sock"

        if [ -z "''${1:-}" ]; then
          echo "Usage: havm-snapshot-delete <snapshot-name>"
          echo ""
          havm-snapshot-list
          exit 1
        fi

        SNAPSHOT_NAME="$1"

        echo "=== Deleting snapshot: $SNAPSHOT_NAME ==="

        if [ ! -f "$QCOW2_PATH" ]; then
          echo "ERROR: qcow2 file not found: $QCOW2_PATH"
          exit 1
        fi

        # Check if VM is running - if so, use QMP
        if [ -S "$QMP_SOCK" ] && ${pkgs.procps}/bin/pgrep -f "qemu.*homeassistant" > /dev/null 2>&1; then
          echo "VM is running, deleting snapshot via QMP..."
          RESULT=$(echo '{"execute":"qmp_capabilities"}
    {"execute":"human-monitor-command","arguments":{"command-line":"delvm '"$SNAPSHOT_NAME"'"}}' | \
            ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QMP_SOCK" 2>&1)

          if echo "$RESULT" | ${pkgs.gnugrep}/bin/grep -q '"error"'; then
            echo "ERROR: Failed to delete snapshot via QMP"
            echo "$RESULT"
            exit 1
          fi
          echo "Snapshot '$SNAPSHOT_NAME' deleted"
        else
          if ${pkgs.qemu}/bin/qemu-img snapshot -d "$SNAPSHOT_NAME" "$QCOW2_PATH"; then
            echo "Snapshot '$SNAPSHOT_NAME' deleted"
          else
            echo "ERROR: Failed to delete snapshot"
            exit 1
          fi
        fi
  '';

  snapshotCleanupScript = pkgs.writeScriptBin "havm-snapshot-cleanup" ''
        #!${pkgs.bash}/bin/bash
        set -euo pipefail

        QCOW2_PATH="${haConfig.haosImagePath}"
        QMP_SOCK="/var/lib/havm/qmp.sock"
        MAX_SNAPSHOTS=2

        echo "=== Cleaning up old snapshots (keeping $MAX_SNAPSHOTS most recent) ==="

        if [ ! -f "$QCOW2_PATH" ]; then
          echo "ERROR: qcow2 file not found: $QCOW2_PATH"
          exit 1
        fi

        # Get list of snapshots sorted by ID (oldest first)
        # qemu-img snapshot -l output format:
        # Snapshot list:
        # ID        TAG                 VM SIZE                DATE       VM CLOCK
        # 1         pre-update-xxx      0                      2024-01-01 00:00:00   00:00:00.000
        # Use --force-share to read snapshot list while VM may be running
        SNAPSHOTS=$(${pkgs.qemu}/bin/qemu-img snapshot -l --force-share "$QCOW2_PATH" 2>/dev/null | \
          ${pkgs.gawk}/bin/awk 'NR>2 && NF>0 {print $2}' | \
          ${pkgs.coreutils}/bin/head -n -$MAX_SNAPSHOTS)

        if [ -z "$SNAPSHOTS" ]; then
          echo "No snapshots to clean up"
          havm-snapshot-list
          exit 0
        fi

        # Check if VM is running - if so, use QMP
        VM_RUNNING=false
        if [ -S "$QMP_SOCK" ] && ${pkgs.procps}/bin/pgrep -f "qemu.*homeassistant" > /dev/null 2>&1; then
          VM_RUNNING=true
          echo "VM is running, will use QMP for deletion"
        fi

        echo "Deleting old snapshots:"
        for SNAP in $SNAPSHOTS; do
          echo "  Deleting: $SNAP"
          if [ "$VM_RUNNING" = true ]; then
            echo '{"execute":"qmp_capabilities"}
    {"execute":"human-monitor-command","arguments":{"command-line":"delvm '"$SNAP"'"}}' | \
              ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QMP_SOCK" > /dev/null 2>&1 || true
          else
            ${pkgs.qemu}/bin/qemu-img snapshot -d "$SNAP" "$QCOW2_PATH" || true
          fi
        done

        echo ""
        echo "Cleanup complete"
        havm-snapshot-list
  '';
in {
  environment.systemPackages = [
    snapshotCreateScript
    snapshotListScript
    snapshotRestoreScript
    snapshotDeleteScript
    snapshotCleanupScript
  ];
}
