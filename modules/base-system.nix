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

  # Simple network configuration - just use DHCP
  # On bare metal, the Home Assistant VM will use macvtap to get its own IP from the network's DHCP
  networking.useDHCP = lib.mkDefault true;

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
