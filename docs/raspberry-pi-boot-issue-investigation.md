# Raspberry Pi 4 Boot Issue Investigation

**Date:** December 26, 2025
**Status:** RESOLVED
**Last Updated:** December 26, 2025

## Problem Summary

After auto-updates or rebuilds, Pi 4 would show management console not starting, appearing stuck. SSH access worked fine but the display showed no management UI.

## Investigation Timeline

### Initial (Wrong) Hypothesis: `/boot/firmware` Mount Issue

**Original Theory:**
- The SD image module sets `/boot/firmware` with `noauto` mount option
- extlinux bootloader needs to write to `/boot/firmware/extlinux/extlinux.conf`
- Since firmware isn't mounted, bootloader writes fail silently

**Why This Was Wrong:**

After thorough investigation on December 26, 2025, we discovered:

```bash
[root@kaliunbox:~]# ls -la /boot/extlinux/
total 12
drwxr-xr-x 2 root root 4096 Dec 26 21:09 .
drwxr-xr-x 4 root root 4096 Jan  1  1970 ..
-rw-r--r-- 1 root root 4056 Dec 26 21:09 extlinux.conf

[root@kaliunbox:~]# mount /dev/mmcblk1p1 /mnt/firmware
[root@kaliunbox:~]# ls -la /mnt/firmware/extlinux/
ls: cannot access '/mnt/firmware/extlinux/': No such file or directory
```

**Key Finding:** The extlinux bootloader config lives on the **ROOT partition** at `/boot/extlinux/extlinux.conf`, NOT on the firmware partition!

The firmware partition (`/dev/mmcblk1p1`) only contains:
- GPU firmware files (start*.elf, bootcode.bin, fixup*.dat)
- Device tree blobs (bcm2711-rpi-4-b.dtb, etc.)
- U-Boot bootloader (u-boot-rpi4.bin)
- config.txt

**Raspberry Pi Boot Chain:**
1. GPU firmware (bootcode.bin) loads from firmware partition
2. GPU reads config.txt which launches U-Boot
3. U-Boot loads extlinux.conf from `/boot/extlinux/` on **root partition** (always mounted)
4. extlinux boots the selected NixOS generation

Since `/boot/extlinux/` is on the root partition, the `noauto` mount option for the firmware partition was **never the actual issue**.

---

## Actual Root Cause: Service Conflicts

### The Real Bug

In `rpi4-direct.nix`, the first-boot claiming service had these directives:

```nix
systemd.services.kaliunbox-first-boot = {
  # ...
  wantedBy = ["multi-user.target"];
  after = ["network-online.target"];
  wants = ["network-online.target"];
  conflicts = ["management-console.service"];  # ← THE PROBLEM
  before = ["management-console.service" "kaliunbox-boot-health.service"];
  # ...
  unitConfig = {
    ConditionPathExists = "!/var/lib/kaliun/config.json";  # Only run if NOT claimed
  };
};
```

### Why This Caused the Issue

1. **On first boot (unclaimed):**
   - `ConditionPathExists` passes (no config.json yet)
   - first-boot service runs, claims device, completes
   - management-console starts after first-boot finishes
   - Everything works

2. **On subsequent boots (already claimed):**
   - `ConditionPathExists` **fails** (config.json exists)
   - first-boot service is **skipped entirely** (condition not met)
   - BUT the `conflicts` directive still applies to the unit definition
   - This creates a subtle systemd ordering issue
   - management-console may not auto-start properly

### The Fix

Removed the `conflicts` and `before` directives from the first-boot service:

```nix
systemd.services.kaliunbox-first-boot = {
  description = "KaliunBox First Boot Setup";
  wantedBy = ["multi-user.target"];
  after = ["network-online.target"];
  wants = ["network-online.target"];
  # conflicts and before REMOVED

  unitConfig = {
    ConditionPathExists = "!/var/lib/kaliun/config.json";
  };
  # ...
};
```

**Result:** Management console now auto-starts correctly on all boots.

---

## Current System State (Working)

### Boot Configuration

```bash
[root@kaliunbox:~]# cat /boot/extlinux/extlinux.conf
# Generated file, all changes will be lost on nixos-rebuild!

DEFAULT nixos-default
TIMEOUT 50

LABEL nixos-default
  MENU LABEL NixOS - Default
  LINUX ../nixos/...-linux-6.12.59-Image
  INITRD ../nixos/...-initrd-linux-6.12.59-initrd
  APPEND init=/nix/store/.../init ...
  FDTDIR ../nixos/...-linux-6.12.59-dtbs

LABEL nixos-11-default
  MENU LABEL NixOS - Configuration 11-default (2025-12-26 19:18)
  ...

# (5 generations shown as per configurationLimit = 5)
```

### NixOS Generations

```bash
[root@kaliunbox:~]# ls -la /nix/var/nix/profiles/
system -> system-11-link
system-11-link -> /nix/store/...-nixos-system-kaliunbox-sd-card-25.11...
system-10-link -> /nix/store/...
# ... generations 7-11 available
```

### Auto-Update Status

The auto-update system should now work correctly because:
1. extlinux.conf is on root partition (always mounted)
2. nixos-rebuild switch updates `/boot/extlinux/extlinux.conf` correctly
3. New generations are added to boot menu
4. `configurationLimit = 5` keeps boot menu manageable

---

## Other Issues Fixed in This Session

### X86 Black Screen After Install

**Symptom:** Fresh x86 VM install showed black screen after claiming, before management console.

**Cause:** An `image-ensure.nix` service was added that blocked boot with:
```nix
requiredBy = ["multi-user.target"];
```

**Fix:** Reverted to original activation script approach for downloading HAOS image. Removed `image-ensure.nix` from imports.

---

## Key Learnings

### 1. Raspberry Pi Boot Architecture

The Pi boot chain is different from what we assumed:

| Component | Location | Purpose |
|-----------|----------|---------|
| GPU Firmware | Firmware partition (mmcblk1p1) | Initial hardware init |
| config.txt | Firmware partition | GPU config, launches U-Boot |
| U-Boot | Firmware partition | Bootloader that reads extlinux |
| extlinux.conf | **Root partition** (/boot/extlinux/) | NixOS generation menu |
| Kernel + initrd | Root partition (/boot/nixos/) | Actual NixOS system |

### 2. systemd Condition Gotchas

When a service has `ConditionPathExists` that fails:
- The service is **skipped** (not run)
- But unit file directives like `conflicts` may still affect other services
- This can cause subtle ordering issues that only appear after first boot

### 3. Debugging Approach

For Pi boot issues, check:
1. `systemctl status <service>` for all related services
2. `journalctl -u <service>` for detailed logs
3. Verify boot config with `cat /boot/extlinux/extlinux.conf`
4. Check generations with `ls -la /nix/var/nix/profiles/`
5. SSH may work even if display shows nothing

---

## Files Modified

1. **rpi4-direct.nix** - Removed `conflicts` and `before` directives from first-boot service
2. **modules/homeassistant/default.nix** - Reverted HAOS download to activation script (for x86 fix)

---

## HAOS VM Recovery Procedure

### Warning: VM Force-Kills Can Corrupt QCOW2

During debugging, if the Home Assistant VM is force-killed (e.g., 120s systemd timeout, `kill -9`, power loss), the qcow2 disk image can become corrupted. Symptoms:

- VM starts but console is blank
- Guest agent not responding
- UEFI stuck, never finds bootable OS
- `homeassistant-status` shows VM running but no IP

### Full Reset Procedure

If HAOS VM is corrupted and won't boot, perform a full reset:

```bash
# Stop the VM
systemctl stop homeassistant-vm.service

# Delete all VM state (THIS ERASES ALL HOME ASSISTANT DATA!)
rm -f /var/lib/kaliun/home-assistant.qcow2
rm -f /var/lib/havm/efivars.fd
rm -f /var/lib/havm/ha_initialized
rm -f /var/lib/havm/startup.img

# Re-run activation to download fresh HAOS image
/run/current-system/activate

# Start the VM (will boot fresh HAOS)
systemctl start homeassistant-vm.service
```

### Important Notes on Backups

- HAOS has built-in backup functionality, but backups are stored INSIDE the qcow2 image
- If the qcow2 is corrupted or deleted, those backups are LOST
- **Recommendation:** Configure HAOS to sync backups to external storage (Google Drive, NAS, etc.)
- The Kaliun Connect backup feature (when implemented) should store backups externally

---

## Verification Commands

To verify Pi is working correctly:

```bash
# Check current generation
readlink /nix/var/nix/profiles/system

# Check boot config
cat /boot/extlinux/extlinux.conf

# Check management console is running
systemctl status management-console.service

# Check all services are healthy
systemctl --failed

# Manual update test
cd /etc/nixos/kaliunbox-flake
git pull
nixos-rebuild switch --flake .#kaliunbox-rpi4
```

---

## References

- [NixOS SD Image Module](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/installer/sd-card/sd-image.nix)
- [NixOS on ARM - NixOS Wiki](https://nixos.wiki/wiki/NixOS_on_ARM)
- [Raspberry Pi Boot Process](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-4-boot-flow)

---

## Status: RESOLVED

The Pi boot and management console issues have been fixed. Auto-updates should work correctly. The original `/boot/firmware` hypothesis was incorrect - the actual issue was a systemd service conflict directive.
