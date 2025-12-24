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

    # Populate firmware partition (extends the default from sd-image-aarch64-installer)
    populateFirmwareCommands = let
      configTxt = pkgs.writeText "config.txt" ''
        # Raspberry Pi 4 configuration for KaliunBox
        arm_64bit=1
        enable_uart=1
        avoid_warnings=1
        
        # Enable audio
        dtparam=audio=on
        
        # GPU memory (minimal for headless)
        gpu_mem=16
        
        # Disable Bluetooth on UART
        dtoverlay=disable-bt
      '';
    in lib.mkAfter ''
      # Copy our custom config.txt
      cp ${configTxt} firmware/config.txt
      
      # Copy kaliunbox flake to firmware partition
      mkdir -p firmware/kaliunbox-flake
      cp -r ${flakeBundle}/. firmware/kaliunbox-flake/
    '';
  };

  # Boot configuration for Raspberry Pi 4
  boot = {
    # Use mainline kernel with Pi 4 support
    kernelPackages = pkgs.linuxPackages_latest;
    
    kernelParams = [
      "console=ttyS0,115200"
      "console=tty1"
      "cma=128M"
    ];

    # Use extlinux for U-Boot
    loader = {
      grub.enable = false;
      generic-extlinux-compatible.enable = true;
      timeout = 3;
    };

    # Initial ramdisk modules
    initrd.availableKernelModules = [
      "usbhid"
      "usb_storage"
      "vc4"
      "bcm2835_dma"
      "i2c_bcm2835"
      "sdhci_iproc"
    ];
  };

  # Hardware
  hardware.enableRedistributableFirmware = true;

  # Network
  networking = {
    hostName = "kaliunbox-installer";
    wireless.enable = false;
    networkmanager.enable = lib.mkForce false;
    useDHCP = true;
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
