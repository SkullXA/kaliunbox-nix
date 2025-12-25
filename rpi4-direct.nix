# KaliunBox Raspberry Pi 4 Direct Boot Image
# This creates a plug-and-play SD card image - flash it and boot directly into KaliunBox
# NO separate installer needed - just like Home Assistant OS
{
  config,
  pkgs,
  lib,
  inputs,
  modulesPath,
  ...
}: {
  imports = [
    # Base SD card image support for aarch64
    "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
    
    # KaliunBox system modules (the actual system, not installer)
    ./modules/base-system.nix
    ./modules/homeassistant
    ./modules/connect-sync.nix
    ./modules/health-reporter.nix
    ./modules/boot-health-check.nix
    ./modules/log-reporter.nix
    ./modules/management-screen.nix
    ./modules/auto-update.nix
    ./modules/network-watchdog.nix
    ./modules/newt-container.nix
  ];

  # SD card image settings
  sdImage = {
    imageName = "kaliunbox-rpi4-direct-${config.system.nixos.label}.img";
    compressImage = true;
    
    # Raspberry Pi 4 firmware partition size
    firmwareSize = 256;
    
    # Expand root filesystem on first boot
    expandOnBoot = true;
  };

  # Raspberry Pi 4 specific boot configuration
  boot = {
    # Use the extlinux bootloader (standard for Pi)
    loader = {
      grub.enable = false;
      generic-extlinux-compatible.enable = true;
    };
    
    # Console for debugging
    kernelParams = [
      "console=ttyS0,115200"
      "console=tty1"
    ];
    
    # Needed for KVM/QEMU virtualization on Pi
    kernelModules = ["kvm-arm"];
  };

  # Hardware support
  hardware = {
    enableRedistributableFirmware = true;
    # Raspberry Pi 4 needs device tree support
    deviceTree.enable = true;
  };

  # Network - Ethernet with DHCP
  networking = {
    hostName = "kaliunbox";
    useDHCP = true;
    wireless.enable = false;
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
    vim
    htop
    parted
    jq
    qrencode
    ncurses
  ];

  # SSH for remote access
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };

  # Allow root login for initial setup
  users.users.root.initialHashedPassword = "";

  # First-boot claiming service
  # This runs on first boot to display QR code and claim the device
  # Uses the same claiming logic as the installer
  systemd.services.kaliunbox-first-boot = {
    description = "KaliunBox First Boot Setup";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target"];
    wants = ["network-online.target"];
    # Prevent management-console from fighting for tty1 during claiming
    conflicts = ["management-console.service"];
    before = ["management-console.service"];
    
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StandardOutput = "tty";
      StandardError = "tty";
      TTYPath = "/dev/tty1";
      TTYReset = true;
      TTYVHangup = true;
      # Only run if not yet claimed (! means "if NOT exists")
      ConditionPathExists = "!/var/lib/kaliun/config.json";
    };
    
    path = with pkgs; [curl jq qrencode util-linux coreutils ncurses git];
    
    script = ''
      export CONNECT_API_URL="https://connect.kaliun.com"
      export STATE_DIR="/var/lib/kaliun"
      export CONFIG_FILE="/var/lib/kaliun/config.json"
      export INSTALL_ID_FILE="/var/lib/kaliun/install_id"
      
      # Use the standard claiming script
      ${builtins.readFile ./installer/claiming/claim-script.sh}
      
      # After claiming succeeds, clone the flake repo for auto-updates
      echo ""
      echo "Setting up auto-update repository..."
      
      FLAKE_DIR="/etc/nixos/kaliunbox-flake"
      if [ ! -d "$FLAKE_DIR" ]; then
        ${pkgs.git}/bin/git clone https://github.com/SkullXA/kaliunbox-nix.git "$FLAKE_DIR"
        echo "Repository cloned successfully"
      fi
      
      # Store the flake target for this device (Pi uses kaliunbox-rpi4)
      echo "kaliunbox-rpi4" > "$STATE_DIR/flake_target"
      echo "Flake target set to: kaliunbox-rpi4"
      
      echo ""
      echo "First boot setup complete!"
    '';
  };

  # Save space
  documentation.enable = false;

  system.stateVersion = "25.11";
}

