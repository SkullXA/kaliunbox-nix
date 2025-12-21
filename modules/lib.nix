# Shared utilities and constants for KaliunBox modules
{pkgs}: {
  # Generate stable MAC address for HA VM from machine-id
  havmMacScript = pkgs.writeShellScript "generate-havm-mac" ''
    MACHINE_ID=$(cat /etc/machine-id)
    MAC_SUFFIX=$(echo "$MACHINE_ID" | head -c 10)
    # Use locally administered MAC address (52:54:01 prefix)
    echo "52:54:01:''${MAC_SUFFIX:0:2}:''${MAC_SUFFIX:2:2}:''${MAC_SUFFIX:4:2}"
  '';

  # State directory for Kaliun configuration
  stateDir = "/var/lib/kaliun";
}
