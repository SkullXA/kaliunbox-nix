# KaliunBox Raspberry Pi 4 SD Card Image
# Creates a bootable SD card image for Raspberry Pi 4
{
  config,
  pkgs,
  lib,
  inputs,
  modulesPath,
  ...
}: let
  # Development mode
  devMode = builtins.getEnv "KALIUNBOX_DEV_MODE" != "";

  flakeBundle = pkgs.runCommand "kaliunbox-flake" {} ''
    mkdir -p $out
    cp -r ${inputs.self}/. $out/
    chmod -R +w $out
    if [ ! -d $out/.git ]; then
      cd $out
      ${pkgs.git}/bin/git init
      ${pkgs.git}/bin/git config user.email "installer@kaliun.com"
      ${pkgs.git}/bin/git config user.name "KaliunBox Installer"
      ${pkgs.git}/bin/git add .
      ${pkgs.git}/bin/git commit -m "Initial commit from installer"
    fi
  '';
in {
  imports = [
    "${modulesPath}/installer/sd-card/sd-image-aarch64-installer.nix"
    ./modules/scripts.nix
    ./modules/auto-claim.nix
    ./modules/welcome.nix
  ];

  # SD card image settings
  sdImage = {
    imageName = "kaliunbox-rpi4-${config.system.nixos.label}.img";
    compressImage = true;
    
    # Increase firmware partition for flake
    firmwareSize = 512;

    # Extend default firmware commands - just add the flake, don't touch boot config
    populateFirmwareCommands = lib.mkAfter ''
      # Copy kaliunbox flake to firmware partition for installer access
      mkdir -p firmware/kaliunbox-flake
      cp -rf ${flakeBundle}/. firmware/kaliunbox-flake/
    '';
  };

  # Boot configuration - let parent module handle most of it
  boot = {
    # Add console for debugging
    kernelParams = [
      "console=ttyS0,115200"
      "console=tty1"
    ];

    # Ensure grub is disabled (use U-Boot/extlinux from parent)
    loader.grub.enable = false;
  };

  # Hardware
  hardware.enableRedistributableFirmware = true;

  # Network - WiFi enabled for Pi (often no Ethernet available)
  networking = {
    hostName = "kaliunbox-installer";
    useDHCP = true;
    
    # Enable WiFi via wpa_supplicant
    wireless = {
      enable = true;
      # Allow imperative configuration (user can add networks at runtime)
      userControlled.enable = true;
    };
    
    # Disable NetworkManager (conflicts with wpa_supplicant)
    networkmanager.enable = lib.mkForce false;
  };

  # Nix settings
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    download-buffer-size = 256 * 1024 * 1024;
  };

  # Essential packages
  environment.systemPackages = with pkgs; [
    git
    curl
    wget
    parted
    dosfstools
    e2fsprogs
    util-linux
    usbutils
    wpa_supplicant  # WiFi configuration
    iw             # WiFi diagnostics
  ];

  # SSH for headless setup
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };

  # Allow passwordless root login for installer (matches other installer modules)
  users.users.root.initialHashedPassword = lib.mkForce "";

  # Save space
  documentation.enable = false;

  system.stateVersion = "25.11";
}
