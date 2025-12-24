# Home Assistant VM systemd service
# Main QEMU virtual machine service for running Home Assistant OS
{
  config,
  pkgs,
  lib,
  ...
}: let
  kaliunLib = import ../lib.nix {inherit pkgs;};
  inherit (kaliunLib) havmMacScript;

  haConfig = import ./config.nix {inherit pkgs;};
  networking = import ./networking.nix {inherit pkgs;};

  # Script to add/remove USB devices from VM via QMP
  usbHotplugScript = pkgs.writeShellScriptBin "havm-usb-hotplug" ''
    ACTION="$1"
    BUSNUM="$2"
    DEVNUM="$3"
    QMP_SOCK="/var/lib/havm/qmp.sock"

    [ -S "$QMP_SOCK" ] || exit 0
    [ -n "$BUSNUM" ] && [ -n "$DEVNUM" ] || exit 0

    # Device ID for QMP (must be unique and stable)
    DEV_ID="usb-$BUSNUM-$DEVNUM"

    if [ "$ACTION" = "add" ]; then
      # Add device via QMP
      (echo '{"execute":"qmp_capabilities"}'; sleep 0.2; \
       echo "{\"execute\":\"device_add\",\"arguments\":{\"driver\":\"usb-host\",\"hostbus\":$BUSNUM,\"hostaddr\":$DEVNUM,\"id\":\"$DEV_ID\"}}") | \
        ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QMP_SOCK" >/dev/null 2>&1
    elif [ "$ACTION" = "remove" ]; then
      # Remove device via QMP
      (echo '{"execute":"qmp_capabilities"}'; sleep 0.2; \
       echo "{\"execute\":\"device_del\",\"arguments\":{\"id\":\"$DEV_ID\"}}") | \
        ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QMP_SOCK" >/dev/null 2>&1
    fi
  '';
in {
  # QEMU systemd service for Home Assistant OS
  # Automatically detects environment and uses appropriate network mode:
  # - Bare metal: bridge (VM gets its own IP from network DHCP)
  # - Nested/VM: user-mode networking with port forwarding (access via host IP:8123)
  systemd.services.homeassistant-vm = {
    description = "Home Assistant OS VM";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];

    # Don't stop/restart VM on config changes - it has persistent state
    # Changes will take effect on next manual restart or reboot
    restartIfChanged = false;

    serviceConfig = {
      Type = "simple";
      Restart = "on-failure";
      RestartSec = "10s";
      # Allow generous time for HAOS to shut down gracefully
      TimeoutStopSec = "180s";
      # QEMU exits with SIGTERM when ACPI powerdown completes - this is normal
      # Without this, systemd reports "Failed with result 'signal'" on clean shutdown
      SuccessExitStatus = "SIGTERM";
    };

    # Graceful shutdown: try guest agent first (more reliable), then fall back to ACPI
    preStop = ''
      echo "Requesting graceful VM shutdown..."
      QGA_SOCK="/var/lib/havm/qga.sock"
      QMP_SOCK="/var/lib/havm/qmp.sock"
      SHUTDOWN_SENT=false

      # Try guest agent first - this is the most reliable method
      # HAOS includes qemu-ga and responds to guest-shutdown
      if [ -S "$QGA_SOCK" ]; then
        echo "Attempting shutdown via guest agent..."
        GA_RESPONSE=$(
          echo '{"execute":"guest-shutdown"}' | \
          ${pkgs.socat}/bin/socat -t5 - UNIX-CONNECT:"$QGA_SOCK" 2>&1
        ) || true
        if echo "$GA_RESPONSE" | ${pkgs.gnugrep}/bin/grep -q '"return"'; then
          echo "Guest agent accepted shutdown command"
          SHUTDOWN_SENT=true
        else
          echo "Guest agent shutdown failed: $GA_RESPONSE"
        fi
      fi

      # Fall back to ACPI via QMP if guest agent failed
      if [ "$SHUTDOWN_SENT" = false ] && [ -S "$QMP_SOCK" ]; then
        echo "Falling back to ACPI shutdown via QMP..."
        QMP_RESPONSE=$(
          (echo '{"execute":"qmp_capabilities"}'; sleep 0.5; echo '{"execute":"system_powerdown"}') | \
          ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$QMP_SOCK" 2>&1
        ) || true
        echo "QMP response: $QMP_RESPONSE"
        SHUTDOWN_SENT=true
      fi

      if [ "$SHUTDOWN_SENT" = false ]; then
        echo "No shutdown method available, VM will be terminated by systemd"
        exit 0
      fi

      # Wait for QEMU to exit gracefully (up to 120s)
      echo "Waiting for VM to shut down..."
      for i in $(seq 1 120); do
        if ! ${pkgs.procps}/bin/pgrep -f "qemu.*homeassistant" > /dev/null 2>&1; then
          echo "VM shut down gracefully after ''${i}s"
          exit 0
        fi
        sleep 1
      done
      echo "VM did not shut down within 120s, will be terminated by systemd"
    '';

    script = ''
            set -euo pipefail

            # Ensure efivars.fd exists (auto-create from template if missing/corrupted)
            EFIVARS_PATH="/var/lib/havm/efivars.fd"
            if [ ! -f "$EFIVARS_PATH" ]; then
              echo "Creating fresh UEFI variables file..."
              cp ${haConfig.uefiVarsPath} "$EFIVARS_PATH"
              chown havm:kvm "$EFIVARS_PATH"
              chmod 660 "$EFIVARS_PATH"
            fi

            # Create startup.nsh FAT image for UEFI shell fallback boot
            # This ensures HAOS boots even if UEFI boot entries are missing/corrupted
            STARTUP_IMG="/var/lib/havm/startup.img"
            # Always recreate startup.img to ensure it has the correct boot script
            echo "Creating UEFI startup disk..."
            rm -f "$STARTUP_IMG"
            # Create 1MB FAT image with startup.nsh
            ${pkgs.coreutils}/bin/dd if=/dev/zero of="$STARTUP_IMG" bs=1M count=1 2>/dev/null
            ${pkgs.dosfstools}/bin/mkfs.vfat "$STARTUP_IMG" >/dev/null
            # Create startup.nsh script that iterates through filesystems to find HAOS
            # This handles QEMU device ordering changes across versions
            TMPDIR=$(mktemp -d)
            BOOT_EFI="${
        if haConfig.isAarch64
        then "\\\\EFI\\\\BOOT\\\\BOOTAA64.EFI"
        else "\\\\EFI\\\\BOOT\\\\BOOTX64.EFI"
      }"
            cat > "$TMPDIR/startup.nsh" << EOFNSH
      @echo -off
      echo Searching for Home Assistant OS...
      for %i in 0 1 2 3 4 5 6 7 8 9
        if exist FS%i:$BOOT_EFI then
          echo Found HAOS on FS%i
          FS%i:
          $BOOT_EFI
        endif
      endfor
      echo ERROR: Could not find Home Assistant OS bootloader
      EOFNSH
            ${pkgs.mtools}/bin/mcopy -i "$STARTUP_IMG" "$TMPDIR/startup.nsh" ::
            rm -rf "$TMPDIR"
            chown havm:kvm "$STARTUP_IMG"
            chmod 640 "$STARTUP_IMG"

            # Generate stable MAC address for this device
            HAVM_MAC=$(${havmMacScript})
            if [ -z "$HAVM_MAC" ]; then
              echo "ERROR: Failed to generate MAC address"
              exit 1
            fi
            echo "VM MAC Address: $HAVM_MAC"

            # Persist MAC address for health check scripts
            echo "$HAVM_MAC" > /var/lib/havm/mac_address

            # Detect if we're running in a hypervisor
            ENV_TYPE=$(${networking.detectHypervisor})
            echo "Environment: $ENV_TYPE"

            # Detect USB devices to pass through at startup (bare metal only)
            # Skip USB passthrough in nested VMs - devices are virtual and conflict with VNC
            USB_ARGS=()
            if [ "$ENV_TYPE" = "bare" ]; then
              for dev in /sys/bus/usb/devices/[0-9]*; do
                [ -f "$dev/bDeviceClass" ] || continue
                class=$(cat "$dev/bDeviceClass")
                [ "$class" = "09" ] && continue  # Skip hubs
                busnum=$(cat "$dev/busnum" 2>/dev/null || echo "")
                devnum=$(cat "$dev/devnum" 2>/dev/null || echo "")
                if [ -n "$busnum" ] && [ -n "$devnum" ]; then
                  product=$(cat "$dev/product" 2>/dev/null || echo "unknown")
                  echo "Passing through USB device: $product (bus $busnum, dev $devnum)"
                  USB_ARGS+=(-device usb-host,hostbus="$busnum",hostaddr="$devnum",id="usb-$busnum-$devnum")
                fi
              done
            else
              echo "Skipping USB passthrough in nested VM environment"
            fi

            # CPU model: always use qemu64 for maximum compatibility
            # - Works with both KVM (fast) and TCG (software emulation)
            # - 'host' CPU requires working KVM and fails in nested VMs
            # - qemu64 with KVM is still very fast, just doesn't expose all CPU features
            # The accel=kvm:tcg in -M will automatically try KVM first, fall back to TCG
            CPU_MODEL="qemu64"
            if [ -e /dev/kvm ] && [ -r /dev/kvm ]; then
              echo "KVM device found - QEMU will try hardware acceleration"
            else
              echo "KVM not available - QEMU will use software emulation (TCG)"
            fi

            # Common QEMU args
            QEMU_ARGS=(
              -name homeassistant
              -M ${haConfig.machineType},accel=kvm:tcg${
        if haConfig.isAarch64
        then ",gic-version=max"
        else ""
      }
              -m 4096
              -smp $(nproc)
              -cpu $CPU_MODEL
              -drive if=pflash,format=raw,readonly=on,file=${haConfig.uefiCodePath}
              -drive if=pflash,format=raw,file=/var/lib/havm/efivars.fd
              -drive file=${haConfig.haosImagePath},if=virtio,format=${haConfig.haosFormat},cache=writeback
              # Startup disk with fallback boot script (UEFI shell auto-executes startup.nsh)
              -drive file=/var/lib/havm/startup.img,if=virtio,format=raw,readonly=on
              # Serial console for headless operation
              -chardev socket,path=/var/lib/havm/console.sock,server=on,wait=off,id=serial0
              -serial chardev:serial0
              # QMP socket for machine control (used for graceful shutdown)
              -qmp unix:/var/lib/havm/qmp.sock,server,nowait
              # Guest agent for VM management
              -device virtio-serial-pci
              -chardev socket,path=/var/lib/havm/qga.sock,server=on,wait=off,id=qga0
              -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0
              # USB controller for device passthrough
              -usb
              -device qemu-xhci,id=xhci
            )

            # Add detected USB devices
            if [ ''${#USB_ARGS[@]} -gt 0 ]; then
              QEMU_ARGS+=("''${USB_ARGS[@]}")
            fi

            # Add display options based on architecture
            # Both architectures get VNC for debugging, plus serial console
            if [ "${
        if haConfig.isAarch64
        then "aarch64"
        else "x86"
      }" = "aarch64" ]; then
              # aarch64: virtio-gpu + keyboard/mouse for VNC (virt machine has no PS/2)
              # Use high PCI addresses (0x10+) to avoid conflict with auto-assigned devices
              QEMU_ARGS+=(-device virtio-gpu-pci,bus=pcie.0,addr=0x10 -device virtio-keyboard-pci,bus=pcie.0,addr=0x11 -device virtio-mouse-pci,bus=pcie.0,addr=0x12 -display none -vnc 127.0.0.1:0)
            else
              # x86: VNC for graphical access, keep serial for potential CLI access
              QEMU_ARGS+=(-display none -vnc 127.0.0.1:0)
            fi

            if [ "$ENV_TYPE" = "bare" ]; then
              # Bare metal: use bridge for direct network access
              echo "Using bridge networking (VM will get its own IP)"

              IFACE=$(${networking.detectPrimaryNic})
              if [ -z "$IFACE" ]; then
                echo "ERROR: No suitable network interface found"
                exit 1
              fi
              echo "Using network interface: $IFACE"

              # Wait for NIC to get an IP via DHCP before setting up bridge
              # This prevents race condition where bridge is created before DHCP completes
              echo "Waiting for $IFACE to get IP address..."
              for i in $(seq 1 60); do
                if ${pkgs.iproute2}/bin/ip -4 addr show "$IFACE" | ${pkgs.gnugrep}/bin/grep -q 'inet '; then
                  echo "$IFACE has IP address"
                  break
                fi
                if [ $i -eq 60 ]; then
                  echo "WARNING: $IFACE did not get IP after 60s, proceeding anyway"
                fi
                sleep 1
              done

              # Setup bridge and get tap device name
              TAP_DEV=$(${networking.setupBridge} "$IFACE")
              echo "Using tap device: $TAP_DEV"

              # Save network mode for health check scripts
              echo "bridge" > /var/lib/havm/network_mode

              echo "Starting QEMU with bridge networking"

              exec ${pkgs.qemu}/bin/${haConfig.qemuBinary} "''${QEMU_ARGS[@]}" \
                -netdev tap,id=net0,ifname=$TAP_DEV,script=no,downscript=no \
                -device virtio-net-pci,netdev=net0,mac=$HAVM_MAC,bus=pcie.0,addr=0x4
            else
              # Nested virtualization: use user-mode networking with port forwarding
              # Port 8123: Home Assistant web UI
              # Port 22222->22: SSH (if SSH add-on is installed in HAOS)
              echo "Using user-mode networking (access Home Assistant at http://<host-ip>:8123)"

              # Save network mode for status script
              echo "usermode" > /var/lib/havm/network_mode

              # SSH port forward: aarch64 (UTM dev) uses 22222->22222 for SSH add-on, x86 uses 22222->22
              SSH_FWD="${
        if haConfig.isAarch64
        then "hostfwd=tcp::22222-:22222"
        else "hostfwd=tcp::22222-:22"
      }"
              exec ${pkgs.qemu}/bin/${haConfig.qemuBinary} "''${QEMU_ARGS[@]}" \
                -netdev user,id=net0,hostfwd=tcp::8123-:8123,hostfwd=tcp::8443-:8443,$SSH_FWD \
                -device virtio-net-pci,netdev=net0,mac=$HAVM_MAC,bus=pcie.0,addr=0x4
            fi
    '';

    postStop = ''
      # Clean up tap device (leave bridge for reconnection)
      ${pkgs.iproute2}/bin/ip link delete tap-haos 2>/dev/null || true
      rm -f /var/lib/havm/network_mode
    '';
  };

  # USB hot-plug support via udev + QMP
  # When USB devices are plugged/unplugged, automatically add/remove from VM
  # Skip hubs (class 09) and HID devices (class 03)
  services.udev.extraRules = ''
    # Add USB device to HAOS VM on plug (skip hubs class 09 and HID class 03)
    ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{bDeviceClass}!="09", ATTR{bDeviceClass}!="03", \
      RUN+="${pkgs.bash}/bin/bash -c '${pkgs.systemd}/bin/systemctl is-active --quiet homeassistant-vm && ${usbHotplugScript}/bin/havm-usb-hotplug add $attr{busnum} $attr{devnum} || true'"

    # Remove USB device from HAOS VM on unplug
    ACTION=="remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", \
      RUN+="${pkgs.bash}/bin/bash -c '${pkgs.systemd}/bin/systemctl is-active --quiet homeassistant-vm && ${usbHotplugScript}/bin/havm-usb-hotplug remove $env{BUSNUM} $env{DEVNUM} || true'"
  '';
}
