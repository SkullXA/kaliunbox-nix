# Home Assistant VM module
# Runs Home Assistant OS in a QEMU virtual machine
# Split into smaller modules for better maintainability
{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  haConfig = import ./config.nix {inherit pkgs;};
in {
  imports = [
    ./vm-service.nix
    ./image-ensure.nix
    ./proxy-setup.nix
    ./info-fetcher.nix
    ./scripts.nix
    ./health-check.nix
    ./watchdog.nix
    ./snapshot-manager.nix
  ];

  # Create dedicated user and kvm group for QEMU VM
  users = {
    users.havm = {
      isSystemUser = true;
      group = "kvm";
      description = "Home Assistant VM service user";
    };
    groups.kvm = {};
  };

  # NOTE: Home Assistant OS image download is handled by havm-ensure-image.service
  # (see image-ensure.nix), which runs after network-online.target.
  # We do NOT download during activation because:
  # 1. Network may not be ready during activation (before systemd starts)
  # 2. curl without timeout can hang indefinitely, blocking boot at "starting systemd..."
  # 3. The image-ensure service has proper retries, progress logging, and validation
  system.activationScripts = {

    # Create directory for Home Assistant VM data
    havmDirectories = lib.stringAfter ["users"] ''
      mkdir -p /var/lib/havm
      chown havm:kvm /var/lib/havm
      chmod 750 /var/lib/havm

      if [ ! -f /var/lib/havm/efivars.fd ]; then
        cp ${haConfig.uefiVarsPath} /var/lib/havm/efivars.fd
      fi
      chown havm:kvm /var/lib/havm/efivars.fd
      chmod 660 /var/lib/havm/efivars.fd
    '';

    # Trigger proxy setup on every rebuild (if VM is running)
    havmProxySetup = lib.stringAfter ["etc"] ''
      if ${pkgs.systemd}/bin/systemctl is-active --quiet homeassistant-vm.service 2>/dev/null; then
        echo "Triggering Home Assistant proxy setup..."
        ${pkgs.systemd}/bin/systemctl restart homeassistant-proxy-setup.service --no-block || true
      fi
    '';
  };

  # Open firewall ports for Home Assistant (used in user-mode networking)
  # 8123: HA web interface
  # 22222: SSH add-on (only in dev/aarch64 builds)
  networking.firewall.allowedTCPPorts =
    [8123]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isAarch64 [22222];

  # Prevent DHCP client from running on VM network interfaces
  # - tap-haos: the VM's tap device (VM gets its own DHCP from the network)
  # - br-haos: the bridge interface (gets IP migrated from physical NIC, not from DHCP)
  # - macvtap*: any macvtap devices created for VM networking
  # The bridge receives its IP from the physical interface during setup, so we don't
  # want dhcpcd requesting additional IPs on it (which causes IP accumulation).
  networking.dhcpcd.denyInterfaces = ["macvtap*" "tap-*" "br-haos"];
}
