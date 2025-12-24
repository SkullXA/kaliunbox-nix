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

    mkdir -p "$(dirname "$IMG")"

    if [ -f "$IMG" ] && [ -s "$IMG" ]; then
      echo "HAOS image present: $IMG ($(stat -c%s "$IMG" 2>/dev/null || echo "?") bytes)"
      exit 0
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

    mv "$TMP_XZ" "''${IMG}.xz"
    echo "Download complete; decompressing..."
    ${pkgs.xz}/bin/xz -d "''${IMG}.xz"

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


