# Home Assistant OS image ensure service
# Ensures the HAOS qcow2 exists at runtime and logs progress to journald (so Connect can display it).
{
  config,
  pkgs,
  lib,
  ...
}: let
  haConfig = import ./config.nix {inherit pkgs;};
  ensureScript = pkgs.writeShellScriptBin "havm-ensure-image" ''
    set -euo pipefail

    IMG="${haConfig.haosImagePath}"
    URL="${haConfig.haosUrl}"
    TMP_XZ="''${IMG}.xz.part"
    MIN_BYTES=$((512 * 1024 * 1024))  # 512MB sanity check to catch partial/corrupt downloads

    mkdir -p "$(dirname "$IMG")"

    if [ -f "$IMG" ] && [ -s "$IMG" ]; then
      SIZE=$(stat -c%s "$IMG" 2>/dev/null || echo "0")
      echo "HAOS image found: $IMG (''${SIZE} bytes)"

      # Detect common failure mode: user powers off mid-download → a small/invalid qcow2 remains,
      # VM boots into maintenance mode and never becomes reachable.
      if [ "$SIZE" -lt "$MIN_BYTES" ]; then
        echo "HAOS image looks too small (<512MB). Treating as corrupt and re-downloading."
      elif ! ${pkgs.qemu}/bin/qemu-img info "$IMG" >/dev/null 2>&1; then
        echo "HAOS image is not a valid qcow2 (qemu-img info failed). Re-downloading."
      else
        echo "HAOS image validated (qemu-img info OK)."
        exit 0
      fi

      rm -f "$IMG"
    fi

    echo "HAOS image missing; downloading ${haConfig.haosVersion} from:"
    echo "  $URL"

    rm -f "$IMG" "$TMP_XZ" "''${IMG}.xz"

    # Download with retries; curl progress bars don't render well in journald, so we log periodic sizes instead.
    echo "Downloading to $TMP_XZ ..."
    ${pkgs.curl}/bin/curl -L --fail --show-error \
      --retry 10 --retry-delay 3 --retry-connrefused \
      --connect-timeout 15 --max-time 0 \
      -o "$TMP_XZ" "$URL" &

    CURL_PID=$!
    while kill -0 "$CURL_PID" 2>/dev/null; do
      if [ -f "$TMP_XZ" ]; then
        SIZE=$(stat -c%s "$TMP_XZ" 2>/dev/null || echo "0")
        echo "Download progress: ''${SIZE} bytes"
      else
        echo "Download progress: starting..."
      fi
      sleep 10
    done

    wait "$CURL_PID"
    CURL_EXIT=$?

    if [ "$CURL_EXIT" -ne 0 ]; then
      echo "ERROR: Download failed (exit code $CURL_EXIT)"
      rm -f "$TMP_XZ"
      exit 1
    fi

    if [ ! -f "$TMP_XZ" ] || [ ! -s "$TMP_XZ" ]; then
      echo "ERROR: Download file missing or empty"
      exit 1
    fi

    mv "$TMP_XZ" "''${IMG}.xz"
    echo "Download complete; decompressing..."
    ${pkgs.xz}/bin/xz -d "''${IMG}.xz"

    # Auto-size the qcow2 based on available disk space
    # Reserve 10GB for NixOS system (base ~6GB + generations + logs + updates buffer)
    DISK_DIR="$(dirname "$IMG")"
    AVAILABLE_KB=$(df -k "$DISK_DIR" | tail -1 | awk '{print $4}')
    AVAILABLE_GB=$((AVAILABLE_KB / 1024 / 1024))

    # Current qcow2 virtual size
    CURRENT_SIZE_BYTES=$(${pkgs.qemu}/bin/qemu-img info --output=json "$IMG" | ${pkgs.jq}/bin/jq -r '."virtual-size"')
    CURRENT_SIZE_GB=$((CURRENT_SIZE_BYTES / 1024 / 1024 / 1024))

    # Calculate target: available space minus 10GB buffer, clamped to 10-200GB range
    RESERVE_GB=10
    TARGET_GB=$((AVAILABLE_GB - RESERVE_GB + CURRENT_SIZE_GB))

    # Clamp to reasonable range
    if [ "$TARGET_GB" -lt 10 ]; then
      TARGET_GB=10
    elif [ "$TARGET_GB" -gt 200 ]; then
      TARGET_GB=200
    fi

    echo "Disk space: ''${AVAILABLE_GB}GB available, current HAOS disk: ''${CURRENT_SIZE_GB}GB"
    echo "Resizing HAOS virtual disk to ''${TARGET_GB}GB..."
    ${pkgs.qemu}/bin/qemu-img resize "$IMG" "''${TARGET_GB}G"
    echo "HAOS virtual disk resized to ''${TARGET_GB}GB (HAOS will auto-expand filesystem on boot)"

    chown havm:kvm "$IMG" || true
    chmod 660 "$IMG" || true

    echo "HAOS image ready: $IMG"
  '';
in {
  systemd.services.havm-ensure-image = {
    description = "Ensure Home Assistant OS image exists (downloads if missing)";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      RemainAfterExit = true;
      # Timeout for the entire download+decompress (30 min should be plenty even on slow connections)
      TimeoutStartSec = "30min";
    };
    script = "${ensureScript}/bin/havm-ensure-image";
  };

  # Make VM depend on the image existing at runtime
  systemd.services.homeassistant-vm = {
    after = ["havm-ensure-image.service"];
    requires = ["havm-ensure-image.service"];
  };

  environment.systemPackages = [ensureScript];
}


