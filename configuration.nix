{
  config,
  pkgs,
  lib,
  ...
}: {
  # Include hardware configuration (generated on installation)
  # Only import if file exists (won't exist during flake evaluation/build)
  imports = lib.optionals (builtins.pathExists /etc/nixos/hardware-configuration.nix) [
    /etc/nixos/hardware-configuration.nix
  ];

  # System identification
  system.stateVersion = "25.05";
  networking.hostName = "kaliunbox";

  # Boot configuration
  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
      timeout = 5; # 5 second timeout to allow boot menu access for troubleshooting
    };
    # Load KVM modules based on architecture
    kernelModules =
      ["tun"]
      ++ (
        if pkgs.stdenv.hostPlatform.isAarch64
        then ["kvm"] # ARM64 uses generic kvm module
        else ["kvm-intel" "kvm-amd"] # x86_64 uses vendor-specific modules
      );
    # Enable KVM support in kernel
    kernelParams = lib.optionals pkgs.stdenv.hostPlatform.isAarch64 ["kvm-arm.mode=nvhe"];
  };

  system.activationScripts.kaliunDirectories = ''
    mkdir -p /var/lib/kaliun
    chmod 755 /var/lib/kaliun
    if [ -f /var/lib/kaliun/config.json ]; then
      chmod 644 /var/lib/kaliun/config.json
    fi
  '';

  # Time zone and internationalization
  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # Console configuration
  console = {
    font = "Lat2-Terminus16";
    keyMap = "us";
  };

  # Root user configuration
  users.users.root = {
    # Empty string = passwordless login on local console (NOT via SSH)
    initialHashedPassword = "";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH0KdFK3xI5pHa3aZYAmZq3w0uyixT+FpE1lIIyPMZq6"
    ];
  };

  # Enable SSH for remote management
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # Firewall configuration
  networking.firewall = {
    enable = true;
    # Allow SSH
    allowedTCPPorts = [22];
  };

  # Enable flakes and nix command
  nix = {
    package = pkgs.nixVersions.stable;
    settings = {
      experimental-features = ["nix-command" "flakes"];
      # Automatic garbage collection
      auto-optimise-store = true;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  # System packages installed globally
  environment.systemPackages = with pkgs; [
    git
    curl
    wget
    jq
    vim
    htop
    qrencode
    tmux
  ];

  # Virtualization support (Home Assistant runs in QEMU VM)
  virtualisation = {
    libvirtd.enable = false;
  };

  # Dummy root filesystem (overridden by hardware-configuration.nix on real hardware)
  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  boot.loader.grub.device = lib.mkDefault "/dev/sda";
}
