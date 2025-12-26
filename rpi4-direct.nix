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
      generic-extlinux-compatible = {
        enable = true;
        # Limit boot menu to 5 generations (saves space and keeps menu manageable)
        configurationLimit = 5;
      };
      # Timeout in seconds before auto-boot (0 = instant boot to default)
      timeout = 5;
    };

    # Console for debugging + KVM support
    kernelParams = [
      "console=ttyS0,115200"
      "console=tty1"
      "kvm-arm.mode=nvhe"  # Enable KVM support for ARM
    ];

    # Needed for KVM/QEMU virtualization on Pi
    kernelModules = ["kvm" "tun"];  # ARM64 uses generic kvm module + tun for VM networking
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

  # Nix settings (match x86/aarch64 configuration)
  nix = {
    package = pkgs.nixVersions.stable;
    settings = {
      experimental-features = ["nix-command" "flakes"];
      download-buffer-size = 256 * 1024 * 1024;
      auto-optimise-store = true;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  # Time zone and locale (match x86/aarch64)
  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # Firewall (allow SSH + HA)
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [22 8123];
  };

  # Essential packages (match x86/aarch64)
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
    tmux
  ];

  # Ensure kaliun directories exist (match x86/aarch64)
  system.activationScripts.kaliunDirectories = ''
    mkdir -p /var/lib/kaliun
    chmod 755 /var/lib/kaliun
    if [ -f /var/lib/kaliun/config.json ]; then
      chmod 644 /var/lib/kaliun/config.json
    fi
  '';

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
    before = ["management-console.service" "kaliunbox-boot-health.service"];

    # Only run if not yet claimed (! means "if NOT exists")
    # This must be in unitConfig, not serviceConfig
    unitConfig = {
      ConditionPathExists = "!/var/lib/kaliun/config.json";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
      StandardOutput = "tty";
      StandardError = "tty";
      TTYPath = "/dev/tty1";
      TTYReset = true;
      TTYVHangup = true;
    };
    
    path = with pkgs; [curl jq qrencode util-linux coreutils ncurses git];
    
    script = ''
      export CONNECT_API_URL="https://connect.kaliun.com"
      export STATE_DIR="/var/lib/kaliun"
      export CONFIG_FILE="/var/lib/kaliun/config.json"
      export INSTALL_ID_FILE="/var/lib/kaliun/install_id"
      
      # Helper to output to tty1
      out() {
        echo "$@" > /dev/tty1
      }
      
      # Show boot screen
      ${pkgs.ncurses}/bin/tput clear > /dev/tty1
      out ""
      out ""
      out "  ========================================"
      out "  KaliunBox - Raspberry Pi"
      out "  ========================================"
      out ""
      out "  Waiting for network connection..."
      out ""
      
      # Wait for API to be reachable (network-online.target doesn't guarantee internet)
      until ${pkgs.curl}/bin/curl -s -m 5 "$CONNECT_API_URL/health" >/dev/null 2>&1; do
        sleep 2
      done
      
      out "  Network connected!"
      sleep 1
      
      # Source the claiming script to get all functions
      # Temporarily disable strict mode to allow function redefinition
      set +euo
      ${builtins.readFile ./installer/claiming/claim-script.sh}
      set -euo pipefail
      
      # Override show_success for Pi (don't say "Proceeding to installation")
      show_success() {
          local config="$1"
          local customer_name=$(echo "$config" | ${pkgs.jq}/bin/jq -r '.customer.name // "Unknown"')
          local customer_contact=$(echo "$config" | ${pkgs.jq}/bin/jq -r '.customer.email // "Unknown"')
          
          ${pkgs.ncurses}/bin/tput clear > /dev/tty1
          out ""
          out ""
          out "  ========================================"
          out "  Device Claimed Successfully!"
          out "  ========================================"
          out ""
          out "  Customer: $customer_name"
          out "  Contact:  $customer_contact"
          out ""
          out ""
          out "  Finalizing setup..."
          out ""
          sleep 2
      }
      
      # Run the claiming process
      main
      
      # After claiming succeeds, clone the flake repo for auto-updates
      out ""
      out "  Setting up auto-update repository..."
      
      FLAKE_DIR="/etc/nixos/kaliunbox-flake"
      if [ ! -d "$FLAKE_DIR" ]; then
        # Clone with timeout (60 seconds) to prevent hanging
        # Use coreutils timeout command with full path
        if ${pkgs.coreutils}/bin/timeout 60 ${pkgs.git}/bin/git clone --depth 1 https://github.com/SkullXA/kaliunbox-nix.git "$FLAKE_DIR" 2>/dev/null; then
          out "  Repository cloned successfully"
        else
          out "  Warning: Could not clone repository (will retry on next update)"
        fi
      else
        out "  Repository already exists"
      fi
      
      # Store the flake target for this device (Pi uses kaliunbox-rpi4)
      echo "kaliunbox-rpi4" > "$STATE_DIR/flake_target"
      out "  Flake target: kaliunbox-rpi4"
      
      out ""
      out "  ========================================"
      out "  First Boot Setup Complete!"
      out "  ========================================"
      out ""
      out "  Starting management console..."
      out ""
      sleep 2

      # Explicitly start management console since 'conflicts' blocks it from auto-starting
      ${pkgs.systemd}/bin/systemctl start management-console.service --no-block || true
    '';
  };

  # Save space
  documentation.enable = false;

  system.stateVersion = "25.11";
}

