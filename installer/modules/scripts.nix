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

    # Thorough disk cleanup
    echo "Unmounting existing partitions..."
    for part in $(lsblk -ln -o NAME "$DISK_PATH" 2>/dev/null | tail -n +2); do
      echo "  Unmounting /dev/$part..."
      umount -l "/dev/$part" 2>/dev/null || true
      umount -f "/dev/$part" 2>/dev/null || true
    done
    umount -l "$DISK_PATH"?* 2>/dev/null || true
    umount -l "$DISK_PATH"p* 2>/dev/null || true
    
    # Deactivate swap
    for part in $(lsblk -ln -o NAME "$DISK_PATH" 2>/dev/null | tail -n +2); do
      swapoff "/dev/$part" 2>/dev/null || true
    done

    # Stop udev from interfering
    echo "Stopping udev..."
    udevadm control --stop-exec-queue 2>/dev/null || true
    
    # Close device-mapper devices
    for dm in $(lsblk -ln -o NAME "$DISK_PATH" 2>/dev/null | grep "^dm-" || true); do
      dmsetup remove -f "/dev/$dm" 2>/dev/null || true
    done
    
    # Stop RAID arrays
    mdadm --stop --scan 2>/dev/null || true
    
    # Flush and sync
    echo "Flushing buffers..."
    sync
    sleep 1
    blockdev --flushbufs "$DISK_PATH" 2>/dev/null || true
    
    # Explicitly delete all partitions using sfdisk
    echo "Deleting existing partitions..."
    sfdisk --delete "$DISK_PATH" 2>/dev/null || true
    sync
    sleep 1
    
    # Use sgdisk to completely zap the disk
    echo "Zapping disk with sgdisk..."
    sgdisk --zap-all "$DISK_PATH" 2>/dev/null || true
    sync
    sleep 1

    # Zero partition table areas (10MB at start and end)
    echo "Zeroing partition table areas..."
    dd if=/dev/zero of="$DISK_PATH" bs=1M count=10 conv=notrunc status=none 2>/dev/null || true
    DISK_SIZE_SECTORS=$(blockdev --getsz "$DISK_PATH" 2>/dev/null || echo "0")
    if [ "$DISK_SIZE_SECTORS" -gt 20480 ]; then
      dd if=/dev/zero of="$DISK_PATH" bs=512 count=20480 seek=$((DISK_SIZE_SECTORS - 20480)) conv=notrunc status=none 2>/dev/null || true
    fi
    sync

    # Wipe signatures
    echo "Wiping disk signatures..."
    wipefs -af "$DISK_PATH" 2>/dev/null || true
    sync
    sleep 2

    # Re-enable udev
    udevadm control --start-exec-queue 2>/dev/null || true
    udevadm settle --timeout=10 2>/dev/null || true
    udevadm trigger --subsystem-match=block --action=change 2>/dev/null || true
    sleep 2

    # Final partition table re-read
    blockdev --rereadpt "$DISK_PATH" 2>/dev/null || true
    partprobe "$DISK_PATH" 2>/dev/null || true
    sleep 3

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
    
    # Disk management (for partition cleanup)
    lvm2
    mdadm

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
