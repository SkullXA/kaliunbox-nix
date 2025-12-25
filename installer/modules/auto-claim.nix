# Auto-claim service for KaliunBox installer
# Handles automatic device claiming and installation on boot
{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  # Development mode - set via environment or default to production
  devMode = builtins.getEnv "KALIUNBOX_DEV_MODE" != "";
  connectApiUrl =
    if devMode
    then builtins.getEnv "KALIUNBOX_API_URL"
    else "https://kaliun-connect-api-production.up.railway.app";

  # Script to wait for network and show connection status
  waitForNetwork =
    if devMode
    then ''
      # Development mode - show clean screen
      ${pkgs.ncurses}/bin/tput clear > /dev/tty1
      {
        echo ""
        echo ""
        echo "  ========================================"
        echo "  KaliunBox Installer - DEV MODE"
        echo "  ========================================"
        echo ""
        echo "  API Endpoint: ${connectApiUrl}"
        echo ""
        echo "  Checking network connectivity..."
        echo ""
      } > /dev/tty1

      # Retry network check with visual animation
      MAX_RETRIES=10
      RETRY_COUNT=0
      API_REACHABLE=false
      SPINNER=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )

      while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        SPIN_IDX=$((RETRY_COUNT % 10))
        printf "\r  ''${SPINNER[$SPIN_IDX]} Attempt %d/%d..." "$((RETRY_COUNT + 1))" "$MAX_RETRIES" > /dev/tty1

        if ${pkgs.curl}/bin/curl -s -m 3 ${connectApiUrl}/health >/dev/null 2>&1; then
          API_REACHABLE=true
          printf "\r  ✓ Connected!                    \n" > /dev/tty1
          break
        fi

        RETRY_COUNT=$((RETRY_COUNT + 1))
        [ $RETRY_COUNT -lt $MAX_RETRIES ] && sleep 1
      done

      if [ "$API_REACHABLE" = "false" ]; then
        printf "\r  ✗ Connection failed             \n" > /dev/tty1
        {
          echo ""
          echo "  ⚠ WARNING: Cannot reach API"
          echo ""
          echo "  Tried $MAX_RETRIES times without success."
          echo "  The claiming process will likely fail."
          echo ""
          echo "  Press Enter to continue anyway,"
          echo "  or Ctrl+C to abort..."
          echo ""
        } > /dev/tty1
        read
      else
        echo "" > /dev/tty1
      fi
    ''
    else ''
      # Production mode - wait for network with helpful status
      ${pkgs.ncurses}/bin/tput clear > /dev/tty1
      {
        echo ""
        echo ""
        echo "  ========================================"
        echo "  KaliunBox Installer"
        echo "  ========================================"
        echo ""
        echo "  Waiting for network connection..."
        echo ""
      } > /dev/tty1

      # Check network interfaces
      ETH_IFACE=$(${pkgs.iproute2}/bin/ip -o link show | ${pkgs.gnugrep}/bin/grep -E 'link/ether' | ${pkgs.gnugrep}/bin/grep -vE '(wl|br|docker|veth|tap)' | ${pkgs.gawk}/bin/awk -F': ' '{print $2}' | head -1)
      
      if [ -n "$ETH_IFACE" ]; then
        echo "  Ethernet interface: $ETH_IFACE" > /dev/tty1
        
        # Check if cable is connected
        CARRIER=$(cat /sys/class/net/$ETH_IFACE/carrier 2>/dev/null || echo "0")
        if [ "$CARRIER" = "1" ]; then
          echo "  Cable status: Connected ✓" > /dev/tty1
        else
          echo "  Cable status: Not connected ✗" > /dev/tty1
          echo "" > /dev/tty1
          echo "  ⚠ Please connect an Ethernet cable" > /dev/tty1
        fi
      else
        echo "  ⚠ No Ethernet interface found" > /dev/tty1
      fi
      
      echo "" > /dev/tty1
      echo "  Connecting to KaliunBox servers..." > /dev/tty1
      echo "" > /dev/tty1

      # Retry loop with status
      ATTEMPT=1
      while true; do
        printf "\r  Attempt %d - " "$ATTEMPT" > /dev/tty1
        
        if ${pkgs.curl}/bin/curl -s -m 5 ${connectApiUrl}/health >/dev/null 2>&1; then
          printf "Connected! ✓                    \n" > /dev/tty1
          sleep 1
          break
        else
          printf "Waiting...                      " > /dev/tty1
        fi
        
        # Every 10 attempts, show helpful message
        if [ $((ATTEMPT % 10)) -eq 0 ]; then
          {
            echo ""
            echo ""
            echo "  ────────────────────────────────────"
            echo "  Still waiting for connection..."
            echo ""
            echo "  Troubleshooting:"
            echo "    • Check Ethernet cable is plugged in"
            echo "    • Check router/switch is powered on"
            echo "    • Try a different Ethernet port"
            echo ""
            echo "  For manual setup: Press Alt+F2"
            echo "  ────────────────────────────────────"
            echo ""
          } > /dev/tty1
        fi
        
        ATTEMPT=$((ATTEMPT + 1))
        sleep 3
      done
    '';

  # Script to perform automatic installation
  autoInstallScript = ''
    # After claiming succeeds, start installation wizard
    ${pkgs.ncurses}/bin/tput clear > /dev/tty1

    {
      echo ""
      echo ""
      echo "========================================"
      echo "  KaliunBox Installation"
      echo "========================================"
      echo ""
    } > /dev/tty1

    # Show disk selection on tty1
    exec < /dev/tty1 > /dev/tty1 2>&1

    echo "Detecting installation disk..."
    echo ""

    # Auto-detect writable disks (excluding read-only, USB/removable, and installation media)
    DISK=$(${pkgs.util-linux}/bin/lsblk -d -n -o NAME,SIZE,RO,RM,TYPE | \
      ${pkgs.gnugrep}/bin/grep -E "disk$" | \
      ${pkgs.gawk}/bin/awk '$3==0 && $4==0 {print $1}' | \
      ${pkgs.coreutils}/bin/head -n1)

    if [ -z "$DISK" ]; then
      # Fallback: find any writable disk (not read-only)
      DISK=$(${pkgs.util-linux}/bin/lsblk -d -n -o NAME,RO,TYPE | \
        ${pkgs.gawk}/bin/awk '$2==0 && $3=="disk" {print $1}' | \
        ${pkgs.coreutils}/bin/head -n1)
    fi

    if [ -z "$DISK" ]; then
      echo "ERROR: No writable installation disk found"
      echo ""
      echo "Available disks:"
      ${pkgs.util-linux}/bin/lsblk -d -o NAME,SIZE,RO,RM,TYPE
      echo ""
      echo "Switch to tty2 (Alt+F2) to troubleshoot"
      exit 1
    fi

    DISK_PATH="/dev/$DISK"
    DISK_SIZE=$(${pkgs.util-linux}/bin/lsblk -d -n -o SIZE "$DISK_PATH")

    echo "Installing to: $DISK_PATH ($DISK_SIZE)"
    echo ""

    # Unmount any existing partitions on the disk (more thorough approach)
    echo "Unmounting existing partitions..."
    # First, find and unmount all partitions on this disk
    for part in $(${pkgs.util-linux}/bin/lsblk -ln -o NAME "$DISK_PATH" 2>/dev/null | tail -n +2); do
      echo "  Unmounting /dev/$part..."
      ${pkgs.util-linux}/bin/umount -f "/dev/$part" 2>/dev/null || true
    done
    # Also try direct unmount patterns
    ${pkgs.util-linux}/bin/umount -f "$DISK_PATH"?* 2>/dev/null || true
    ${pkgs.util-linux}/bin/umount -f "$DISK_PATH"p* 2>/dev/null || true
    
    # Deactivate any swap on the disk
    for part in $(${pkgs.util-linux}/bin/lsblk -ln -o NAME "$DISK_PATH" 2>/dev/null | tail -n +2); do
      ${pkgs.util-linux}/bin/swapoff "/dev/$part" 2>/dev/null || true
    done

    # Force kernel to re-read partition table
    echo "Releasing disk..."
    ${pkgs.util-linux}/bin/blockdev --rereadpt "$DISK_PATH" 2>/dev/null || true
    sleep 2

    # Wipe disk signatures
    echo "Wiping disk signatures..."
    ${pkgs.util-linux}/bin/wipefs -af "$DISK_PATH"

    # Inform kernel of partition changes again
    ${pkgs.util-linux}/bin/blockdev --rereadpt "$DISK_PATH" 2>/dev/null || true
    ${pkgs.parted}/bin/partprobe "$DISK_PATH" 2>/dev/null || true
    sleep 3

    # Partition the disk
    echo "Partitioning $DISK_PATH..."
    ${pkgs.parted}/bin/parted -s "$DISK_PATH" -- mklabel gpt
    ${pkgs.parted}/bin/parted -s "$DISK_PATH" -- mkpart ESP fat32 1MiB 512MiB
    ${pkgs.parted}/bin/parted -s "$DISK_PATH" -- set 1 esp on
    ${pkgs.parted}/bin/parted -s "$DISK_PATH" -- mkpart primary 512MiB 100%

    # Inform kernel of partition changes
    ${pkgs.parted}/bin/partprobe "$DISK_PATH"
    sleep 2

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
    ${pkgs.dosfstools}/bin/mkfs.fat -F 32 -n BOOT "$BOOT_PART"
    ${pkgs.e2fsprogs}/bin/mkfs.ext4 -F -L nixos "$ROOT_PART"

    # Mount filesystems
    echo "Mounting filesystems..."
    ${pkgs.util-linux}/bin/mount "$ROOT_PART" /mnt
    ${pkgs.coreutils}/bin/mkdir -p /mnt/boot
    ${pkgs.util-linux}/bin/mount "$BOOT_PART" /mnt/boot

    # Copy configuration to persistent storage
    echo "Copying configuration..."
    ${pkgs.coreutils}/bin/mkdir -p /mnt/var/lib/kaliun
    if [ -d /var/lib/kaliun ] && [ "$(${pkgs.coreutils}/bin/ls -A /var/lib/kaliun)" ]; then
      ${pkgs.coreutils}/bin/cp -r /var/lib/kaliun/* /mnt/var/lib/kaliun/
      ${pkgs.coreutils}/bin/chmod 700 /mnt/var/lib/kaliun
    fi

    # Generate hardware configuration
    echo "Generating hardware configuration..."
    ${pkgs.coreutils}/bin/mkdir -p /mnt/etc/nixos
    ${pkgs.nixos-install-tools}/bin/nixos-generate-config --root /mnt

    # Copy KaliunBox flake (in dev mode) or clone from GitLab (in production)
    ${
      if devMode
      then ''
        echo "Copying KaliunBox configuration (dev mode)..."
        ${pkgs.coreutils}/bin/cp -r /iso/kaliunbox-flake /mnt/etc/nixos/
      ''
      else ''
        echo "Cloning KaliunBox configuration..."
        ${pkgs.git}/bin/git clone https://github.com/SkullXA/kaliunbox-nix.git /mnt/etc/nixos/kaliunbox-flake
      ''
    }

    # Install NixOS - detect architecture at runtime
    echo "Installing NixOS..."
    ARCH=$(${pkgs.coreutils}/bin/uname -m)
    if [ "$ARCH" = "aarch64" ]; then
      FLAKE_CONFIG="kaliunbox-aarch64"
    else
      FLAKE_CONFIG="kaliunbox"
    fi
    echo "Detected architecture: $ARCH, using config: $FLAKE_CONFIG"
    ${pkgs.nixos-install-tools}/bin/nixos-install --flake /mnt/etc/nixos/kaliunbox-flake#$FLAKE_CONFIG --no-root-passwd

    echo ""
    echo "=== Installation Complete ==="
    echo ""
    echo "Please remove the installation media (USB key)"
    echo "and press Enter to reboot..."
    echo ""

    read -r
    ${pkgs.systemd}/bin/reboot
  '';

  # Claim script with dependencies
  claimScriptBin = pkgs.writeScriptBin "kaliunbox-claim" ''
    #!${pkgs.bash}/bin/bash
    export PATH="${pkgs.curl}/bin:${pkgs.jq}/bin:${pkgs.ncurses}/bin:${pkgs.coreutils}/bin:${pkgs.qrencode}/bin:$PATH"
    ${builtins.readFile ../claiming/claim-script.sh}
  '';
in {
  # Enable network-online target for proper network wait
  systemd.services = {
    systemd-networkd-wait-online.enable = true;

    # Pre-start the claiming process during boot
    kaliunbox-auto-claim = {
      description = "KaliunBox Auto-Claim on Boot";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target" "getty@tty1.service"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "simple";
        StandardOutput = "tty";
        StandardError = "tty";
        TTYPath = "/dev/tty1";
        TTYReset = "yes";
        TTYVHangup = "yes";
      };
      path = with pkgs; [
        nix
        nixos-install-tools
        git
        rsync
        util-linux
        e2fsprogs
        dosfstools
        parted
        coreutils
        gawk
        gnugrep
        iproute2
      ];
      script = ''
        # Set Connect API URL
        export CONNECT_API_URL="${connectApiUrl}"

        ${waitForNetwork}

        # Run claiming script (outputs to tty1)
        ${claimScriptBin}/bin/kaliunbox-claim

        ${autoInstallScript}
      '';
    };
  };
}
