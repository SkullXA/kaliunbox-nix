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
      # Production mode - wait for network with timeout and WiFi fallback
      ${pkgs.ncurses}/bin/tput clear > /dev/tty1
      
      show_header() {
        ${pkgs.ncurses}/bin/tput clear > /dev/tty1
        {
          echo ""
          echo ""
          echo "  ========================================"
          echo "  KaliunBox Installer"
          echo "  ========================================"
          echo ""
        } > /dev/tty1
      }
      
      # WiFi setup function
      setup_wifi() {
        show_header
        {
          echo "  WiFi Setup"
          echo "  ----------"
          echo ""
        } > /dev/tty1
        
        # Check if WiFi interface exists
        WIFI_IFACE=$(${pkgs.iw}/bin/iw dev 2>/dev/null | ${pkgs.gnugrep}/bin/grep Interface | ${pkgs.gawk}/bin/awk '{print $2}' | head -1)
        
        if [ -z "$WIFI_IFACE" ]; then
          {
            echo "  ✗ No WiFi adapter detected"
            echo ""
            echo "  Please connect via Ethernet instead."
            echo ""
            echo "  Press Enter to retry connection..."
          } > /dev/tty1
          read < /dev/tty1
          return 1
        fi
        
        {
          echo "  Found WiFi adapter: $WIFI_IFACE"
          echo ""
          echo "  Scanning for networks..."
          echo ""
        } > /dev/tty1
        
        # Bring up interface and scan
        ${pkgs.iproute2}/bin/ip link set "$WIFI_IFACE" up 2>/dev/null
        sleep 2
        
        # Get list of networks
        NETWORKS=$(${pkgs.iw}/bin/iw dev "$WIFI_IFACE" scan 2>/dev/null | ${pkgs.gnugrep}/bin/grep -E "SSID:" | ${pkgs.gnused}/bin/sed 's/.*SSID: //' | ${pkgs.gnugrep}/bin/grep -v "^$" | ${pkgs.coreutils}/bin/sort -u | ${pkgs.coreutils}/bin/head -10)
        
        if [ -z "$NETWORKS" ]; then
          {
            echo "  ✗ No WiFi networks found"
            echo ""
            echo "  Press Enter to retry..."
          } > /dev/tty1
          read < /dev/tty1
          return 1
        fi
        
        {
          echo "  Available networks:"
          echo ""
          i=1
          echo "$NETWORKS" | while read -r ssid; do
            echo "    $i) $ssid"
            i=$((i + 1))
          done
          echo ""
          echo "  Enter network number (or type SSID manually):"
        } > /dev/tty1
        
        read SELECTION < /dev/tty1
        
        # Check if selection is a number
        if echo "$SELECTION" | ${pkgs.gnugrep}/bin/grep -qE '^[0-9]+$'; then
          SSID=$(echo "$NETWORKS" | ${pkgs.gnused}/bin/sed -n "''${SELECTION}p")
        else
          SSID="$SELECTION"
        fi
        
        if [ -z "$SSID" ]; then
          echo "  Invalid selection" > /dev/tty1
          sleep 2
          return 1
        fi
        
        {
          echo ""
          echo "  Enter password for '$SSID':"
        } > /dev/tty1
        
        read -s PASSWORD < /dev/tty1
        
        {
          echo ""
          echo "  Connecting to '$SSID'..."
        } > /dev/tty1
        
        # Create wpa_supplicant config
        ${pkgs.coreutils}/bin/mkdir -p /etc/wpa_supplicant
        ${pkgs.wpa_supplicant}/bin/wpa_passphrase "$SSID" "$PASSWORD" > /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null
        
        # Kill any existing wpa_supplicant
        ${pkgs.procps}/bin/pkill wpa_supplicant 2>/dev/null || true
        sleep 1
        
        # Start wpa_supplicant
        ${pkgs.wpa_supplicant}/bin/wpa_supplicant -B -i "$WIFI_IFACE" -c /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null
        
        # Wait for connection
        sleep 3
        
        # Get IP via DHCP
        ${pkgs.dhcpcd}/bin/dhcpcd -w "$WIFI_IFACE" 2>/dev/null &
        sleep 5
        
        # Check if we got an IP
        if ${pkgs.iproute2}/bin/ip addr show "$WIFI_IFACE" | ${pkgs.gnugrep}/bin/grep -q "inet "; then
          echo "  ✓ WiFi connected!" > /dev/tty1
          sleep 2
          return 0
        else
          echo "  ✗ Failed to connect. Check password." > /dev/tty1
          sleep 3
          return 1
        fi
      }
      
      show_header
      echo "  Checking network connection..." > /dev/tty1
      
      # Try to connect with timeout
      MAX_RETRIES=15
      RETRY_COUNT=0
      CONNECTED=false
      
      while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        printf "\r  Attempt %d/%d..." "$((RETRY_COUNT + 1))" "$MAX_RETRIES" > /dev/tty1
        
        if ${pkgs.curl}/bin/curl -s -m 3 ${connectApiUrl}/health >/dev/null 2>&1; then
          CONNECTED=true
          printf "\r  ✓ Connected!                    \n" > /dev/tty1
          break
        fi
        
        RETRY_COUNT=$((RETRY_COUNT + 1))
        sleep 2
      done
      
      # If not connected, offer WiFi setup
      while [ "$CONNECTED" = "false" ]; do
        {
          echo ""
          echo ""
          echo "  ✗ No internet connection detected"
          echo ""
          echo "  Options:"
          echo "    1) Setup WiFi"
          echo "    2) Retry connection (Ethernet)"
          echo ""
          echo "  Enter choice [1/2]:"
        } > /dev/tty1
        
        read CHOICE < /dev/tty1
        
        case "$CHOICE" in
          1)
            setup_wifi
            ;;
          2)
            show_header
            echo "  Retrying connection..." > /dev/tty1
            ;;
        esac
        
        # Check connection again
        sleep 2
        if ${pkgs.curl}/bin/curl -s -m 5 ${connectApiUrl}/health >/dev/null 2>&1; then
          CONNECTED=true
          show_header
          echo "  ✓ Connected!" > /dev/tty1
          sleep 2
        fi
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

    # Unmount any existing partitions on the disk
    echo "Unmounting existing partitions..."
    ${pkgs.util-linux}/bin/umount "$DISK_PATH"* 2>/dev/null || true

    # Wipe disk signatures
    echo "Wiping disk signatures..."
    ${pkgs.util-linux}/bin/wipefs -af "$DISK_PATH"

    # Inform kernel of partition changes
    ${pkgs.parted}/bin/partprobe "$DISK_PATH" || true
    sleep 2

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
    if [[ "$DISK" =~ nvme ]]; then
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
        gnused
        iw
        iproute2
        wpa_supplicant
        dhcpcd
        procps
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
