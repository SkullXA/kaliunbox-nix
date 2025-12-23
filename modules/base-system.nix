{
  config,
  pkgs,
  lib,
  ...
}: {
  # Core system configuration and utilities

  boot = {
    # Suppress systemd status messages on console (they interfere with management screen)
    kernelParams = ["quiet" "systemd.show_status=false"];
    consoleLogLevel = 0;

    # Blacklist Bluetooth module so Home Assistant VM can use USB Bluetooth directly
    # Note: This disables host Bluetooth entirely (no BT keyboards/mice on host)
    # Appropriate for KaliunBox as a dedicated HA appliance
    blacklistedKernelModules = ["btusb"];

    # System settings for virtualization
    kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
    };
  };

  # Network configuration
  # - DHCP for automatic IP assignment
  # - resolvconf to manage /etc/resolv.conf (allows bridge setup to preserve DHCP DNS)
  # - Fallback DNS servers for when DHCP DNS is lost (e.g., during bridge setup)
  # Note: On restricted networks that block public DNS, DHCP-provided DNS is
  # preserved at bridge setup time via resolvconf. However, DNS won't refresh
  # after setup since br-haos is denied in dhcpcd.denyInterfaces.
  networking = {
    useDHCP = lib.mkDefault true;
    resolvconf.enable = true;
    nameservers = ["1.1.1.1" "8.8.8.8"];
  };

  # Shell aliases and helper functions
  programs.bash.interactiveShellInit = ''
    # Note: Direct command execution in Home Assistant OS VM is not supported
    # Use the web interface at http://<vm-ip>:8123 or homeassistant-console for serial access
  '';

  # Root shell configuration
  programs.bash.shellAliases = {
    ll = "ls -alF";
    la = "ls -A";
    l = "ls -CF";
  };

  # Additional system packages specific to KaliunBox
  environment.systemPackages = with pkgs; [
    # Network tools
    iproute2
    bridge-utils
    nettools
    nmap

    # Monitoring tools
    lsof
    tcpdump

    # Virtualization tools for debugging
    qemu_kvm
    socat

    # Development/debugging
    strace
    gdb
  ];
}
