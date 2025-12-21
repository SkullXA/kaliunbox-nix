# Boot loader configuration for KaliunBox installer ISO
{
  config,
  pkgs,
  lib,
  ...
}: {
  boot = {
    # Override systemd-boot with GRUB2 for branding
    loader = {
      systemd-boot.enable = lib.mkForce false;
      timeout = lib.mkForce 5;
      grub = {
        enable = lib.mkForce true;
        device = lib.mkForce "nodev";
        efiSupport = lib.mkForce true;
        efiInstallAsRemovable = lib.mkForce true;

        # Branding
        splashImage = ../grub-theme/logo.png;
        backgroundColor = "#1a237e";

        # Disable memtest86+ on ARM64 (only available on x86)
        memtest86.enable = lib.mkForce false;
      };
    };

    # Boot settings for installer - no Plymouth, go straight to console
    kernelParams = [];
  };
}
