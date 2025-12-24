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

  # Download Home Assistant OS image at activation
  system.activationScripts = {
    downloadHomeAssistant = lib.stringAfter ["users"] ''
      if [ ! -f "${haConfig.haosImagePath}" ] || [ ! -s "${haConfig.haosImagePath}" ]; then
        echo "Downloading Home Assistant OS ${haConfig.haosVersion}..."
        mkdir -p $(dirname "${haConfig.haosImagePath}")
        rm -f "${haConfig.haosImagePath}" "${haConfig.haosImagePath}.tmp" "${haConfig.haosImagePath}.xz"

        # Fresh image means HA needs to reinitialize - delete the initialization marker
        rm -f /var/lib/havm/ha_initialized

        # Download to temp file first, then decompress
        # xz -d removes .xz extension automatically, producing ${haConfig.haosImagePath}
        # Note: activation output is only visible during nixos-rebuild; runtime boot logs come from the VM service.
        if ${pkgs.curl}/bin/curl --fail --show-error --cacert ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt -L -o "${haConfig.haosImagePath}.xz" "${haConfig.haosUrl}"; then
          ${pkgs.xz}/bin/xz -d "${haConfig.haosImagePath}.xz"
        else
          echo "ERROR: Failed to download Home Assistant OS image"
          rm -f "${haConfig.haosImagePath}.xz"
          exit 1
        fi
      fi
      chown havm:kvm "${haConfig.haosImagePath}"
      chmod 660 "${haConfig.haosImagePath}"
    '';

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
