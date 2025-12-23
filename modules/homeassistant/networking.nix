# Home Assistant VM networking scripts
# Network interface detection, bridge setup, and hypervisor detection
{pkgs, ...}: {
  # Script to find primary network interface (prefers interface with carrier/link)
  detectPrimaryNic = pkgs.writeShellScript "detect-primary-nic" ''
    # Get all ethernet interfaces (exclude virtual, wireless, bridges, etc.)
    IFACES=$(${pkgs.iproute2}/bin/ip -o link show | \
      ${pkgs.gnugrep}/bin/grep -vE '^[0-9]+: (lo|br[0-9]+|br-|virbr|docker|veth|vm-|wl|macvtap|tap)' | \
      ${pkgs.gnugrep}/bin/grep 'link/ether' | \
      ${pkgs.gawk}/bin/awk -F': ' '{print $2}')

    # First, try to find an interface with carrier (cable connected)
    for iface in $IFACES; do
      if [ -f "/sys/class/net/$iface/carrier" ]; then
        carrier=$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo "0")
        if [ "$carrier" = "1" ]; then
          echo "$iface"
          exit 0
        fi
      fi
    done

    # Fallback: return first ethernet interface even without carrier
    echo "$IFACES" | ${pkgs.coreutils}/bin/head -n1
  '';

  # Script to setup bridge for VM networking
  setupBridge = pkgs.writeShellScript "setup-havm-bridge" ''
    set -euo pipefail

    IFACE="$1"
    TAP_NAME="tap-haos"
    BRIDGE_NAME="br-haos"

    # Check if bridge already exists and is properly configured
    if ${pkgs.iproute2}/bin/ip link show "$BRIDGE_NAME" &>/dev/null; then
      # Bridge exists, check if tap is attached
      if ${pkgs.iproute2}/bin/ip link show "$TAP_NAME" &>/dev/null; then
        echo "$TAP_NAME"
        exit 0
      fi
    fi

    # Get current IP config from physical interface
    CURRENT_IP=$(${pkgs.iproute2}/bin/ip -4 addr show "$IFACE" | ${pkgs.gawk}/bin/awk '/inet / {print $2; exit}')
    CURRENT_GW=$(${pkgs.iproute2}/bin/ip route | ${pkgs.gawk}/bin/awk '/default/ {print $3; exit}')

    # Create bridge if it doesn't exist
    if ! ${pkgs.iproute2}/bin/ip link show "$BRIDGE_NAME" &>/dev/null; then
      ${pkgs.iproute2}/bin/ip link add name "$BRIDGE_NAME" type bridge
      ${pkgs.iproute2}/bin/ip link set "$BRIDGE_NAME" up
    fi

    # Create tap device for VM
    if ! ${pkgs.iproute2}/bin/ip link show "$TAP_NAME" &>/dev/null; then
      ${pkgs.iproute2}/bin/ip tuntap add dev "$TAP_NAME" mode tap
    fi
    ${pkgs.iproute2}/bin/ip link set "$TAP_NAME" up
    ${pkgs.iproute2}/bin/ip link set "$TAP_NAME" master "$BRIDGE_NAME"

    # Add physical interface to bridge (if not already)
    if ! ${pkgs.iproute2}/bin/ip link show master "$BRIDGE_NAME" | ${pkgs.gnugrep}/bin/grep -q "$IFACE"; then
      # Save DNS servers before releasing the lease (snapshot of current resolv.conf)
      # Note: This captures all nameservers including static ones from networking.nameservers
      # Re-adding static servers is harmless; the important thing is preserving DHCP DNS
      SAVED_DNS=$(${pkgs.gnugrep}/bin/grep '^nameserver' /etc/resolv.conf 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $2}' || true)

      # Release DHCP lease on physical interface before adding to bridge
      # This prevents dhcpcd from requesting a new IP after we flush it
      ${pkgs.dhcpcd}/bin/dhcpcd -k "$IFACE" 2>/dev/null || true

      # Remove IP from physical interface
      ${pkgs.iproute2}/bin/ip addr flush dev "$IFACE" 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip link set "$IFACE" master "$BRIDGE_NAME"

      # Restore DHCP-provided DNS via resolvconf (proper interface, not direct file write)
      # This preserves DNS from restricted networks that block public resolvers
      if [ -n "$SAVED_DNS" ]; then
        (
          for dns in $SAVED_DNS; do
            echo "nameserver $dns"
          done
        ) | ${pkgs.openresolv}/bin/resolvconf -a "$BRIDGE_NAME.bridge" || true
      fi
    fi

    # Configure bridge with the IP (if we had one)
    if [ -n "$CURRENT_IP" ]; then
      ${pkgs.iproute2}/bin/ip addr add "$CURRENT_IP" dev "$BRIDGE_NAME" 2>/dev/null || true
    fi
    if [ -n "$CURRENT_GW" ]; then
      ${pkgs.iproute2}/bin/ip route add default via "$CURRENT_GW" dev "$BRIDGE_NAME" 2>/dev/null || true
    fi

    echo "$TAP_NAME"
  '';

  # Script to detect if running in a hypervisor (nested virtualization)
  detectHypervisor = pkgs.writeShellScript "detect-hypervisor" ''
    # Check for common hypervisor signatures
    if ${pkgs.systemd}/bin/systemd-detect-virt -q 2>/dev/null; then
      echo "nested"
    elif [ -f /sys/class/dmi/id/product_name ]; then
      PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "")
      case "$PRODUCT" in
        *"Virtual Machine"*|*"VMware"*|*"QEMU"*|*"KVM"*|*"VirtualBox"*|*"Parallels"*|*"UTM"*)
          echo "nested"
          ;;
        *)
          echo "bare"
          ;;
      esac
    else
      echo "bare"
    fi
  '';
}
