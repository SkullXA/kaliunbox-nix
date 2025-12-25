# Helper scripts for KaliunBox installer
{pkgs, ...}: let
  claimScript = pkgs.writeScriptBin "kaliunbox-claim" ''
    #!${pkgs.bash}/bin/bash
    export PATH="${pkgs.curl}/bin:${pkgs.jq}/bin:${pkgs.ncurses}/bin:${pkgs.coreutils}/bin:$PATH"
    ${builtins.readFile ../claiming/claim-script.sh}
  '';

  installScript = pkgs.writeScriptBin "kaliunbox-install" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    echo "=== KaliunBox Installation ==="
    echo ""

    # Step 1: Run claiming process
    echo "Starting device claiming process..."
    echo "This will display a QR code on the boot screen."
    echo ""

    kaliunbox-claim || {
      echo "ERROR: Claiming process failed"
      exit 1
    }

    # Step 2: Prepare for installation
    echo ""
    echo "Device claimed successfully!"
    echo "Configuration downloaded."
    echo ""

    # Step 3: Partition disk
    echo "Select installation disk:"
    lsblk -d -n -o NAME,SIZE,TYPE | grep disk
    echo ""
    read -p "Enter disk name (e.g., sda, nvme0n1): " DISK

    if [ -z "$DISK" ]; then
      echo "ERROR: No disk specified"
      exit 1
    fi

    DISK_PATH="/dev/$DISK"

    if [ ! -b "$DISK_PATH" ]; then
      echo "ERROR: Disk $DISK_PATH not found"
      exit 1
    fi

    echo ""
    echo "WARNING: This will erase all data on $DISK_PATH"
    read -p "Continue? (yes/no): " CONFIRM

    if [ "$CONFIRM" != "yes" ]; then
      echo "Installation cancelled"
      exit 1
    fi

    # Partition the disk
    echo "Partitioning $DISK_PATH..."
    parted -s "$DISK_PATH" -- mklabel gpt
    parted -s "$DISK_PATH" -- mkpart ESP fat32 1MiB 512MiB
    parted -s "$DISK_PATH" -- set 1 esp on
    parted -s "$DISK_PATH" -- mkpart primary 512MiB 100%

    # Determine partition names
    # NVMe and MMC devices use 'p' prefix for partitions (nvme0n1p1, mmcblk1p1)
    # SATA/USB/VirtIO devices don't (sda1, vda1)
    if [[ "$DISK" =~ nvme|mmcblk|loop ]]; then
      BOOT_PART="''${DISK_PATH}p1"
      ROOT_PART="''${DISK_PATH}p2"
    else
      BOOT_PART="''${DISK_PATH}1"
      ROOT_PART="''${DISK_PATH}2"
    fi

    # Format partitions
    echo "Formatting partitions..."
    mkfs.fat -F 32 -n BOOT "$BOOT_PART"
    mkfs.ext4 -L nixos "$ROOT_PART"

    # Mount filesystems
    echo "Mounting filesystems..."
    mount "$ROOT_PART" /mnt
    mkdir -p /mnt/boot
    mount "$BOOT_PART" /mnt/boot

    # Copy configuration to persistent storage
    echo "Copying configuration..."
    mkdir -p /mnt/var/lib/kaliun
    if [ -d /var/lib/kaliun ] && [ "$(ls -A /var/lib/kaliun)" ]; then
      cp -r /var/lib/kaliun/* /mnt/var/lib/kaliun/
      chmod 700 /mnt/var/lib/kaliun
    fi

    # Generate hardware configuration
    echo "Generating hardware configuration..."
    mkdir -p /mnt/etc/nixos
    nixos-generate-config --root /mnt

    # Clone KaliunBox flake
    echo "Cloning KaliunBox configuration..."
    git clone https://github.com/SkullXA/kaliunbox-nix.git /mnt/etc/nixos/kaliunbox-flake

    # Install NixOS
    echo "Installing NixOS..."
    nixos-install --flake /mnt/etc/nixos/kaliunbox-flake#kaliunbox --no-root-passwd

    echo ""
    echo "=== Installation Complete ==="
    echo ""
    echo "Remove installation media and reboot."
    echo ""
    read -p "Reboot now? (yes/no): " REBOOT

    if [ "$REBOOT" = "yes" ]; then
      reboot
    fi
  '';
in {
  environment.systemPackages = with pkgs; [
    # Standard installer tools
    git
    curl
    wget
    jq
    vim
    htop
    parted
    gptfdisk
    rsync

    # Terminal utilities (for claiming script)
    ncurses

    # QR code generation
    qrencode
    qrencode-large

    # KaliunBox scripts
    claimScript
    installScript
  ];
}
