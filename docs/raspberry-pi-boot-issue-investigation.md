# Raspberry Pi 4 Boot Issue Investigation

**Date:** December 26, 2025
**Issue:** Pi 4 hangs at "starting systemd..." after auto-updates, only older generations boot successfully

## Problem Summary

After auto-updates, newer NixOS generations (3+) hang at "starting systemd..." during boot. Only generation 2 ("Configuration 2-default") boots successfully. User must manually select working generation from boot menu every time.

## Root Cause Analysis

### The Bug Introduction Timeline

**Commit ef0f0ca** (Dec 25, 13:54:20 2025): "Switch to direct boot RPi4 image and simplify installer"
- Replaced installer-based approach with direct boot (plug-and-play)
- **Old approach:** Boot installer ISO → Run `kaliunbox-install` → Runs `nixos-install --flake .#kaliunbox` → Reboot into installed system
- **New approach:** Flash SD image → Boot directly into final system → Auto-claim on first boot
- Removed 333 lines, added 166 lines
- Deleted `installer/rpi4-image.nix`
- Created `rpi4-direct.nix`

**Commit dc5809a** (Dec 25, 13:58:29 2025 - **4 minutes later**): "Persist flake target for auto-updates"
- **THIS IS WHERE THE BUG WAS INTRODUCED**
- Added line in `rpi4-direct.nix:247`:
  ```bash
  # Store the flake target for this device (Pi uses kaliunbox-rpi4)
  echo "kaliunbox-rpi4" > "$STATE_DIR/flake_target"
  ```
- Updated `modules/auto-update.nix` to read from `/var/lib/kaliun/flake_target`
- This tells auto-update to rebuild using `kaliunbox-rpi4` flake target
- **Problem:** `kaliunbox-rpi4` imports the SD image module, which is designed for image creation, not live systems

### Technical Root Cause

The SD image module (`nixos/modules/installer/sd-card/sd-image.nix`) contains this filesystem configuration:

```nix
fileSystems = {
  "/boot/firmware" = {
    device = "/dev/disk/by-label/${config.sdImage.firmwarePartitionName}";
    fsType = "vfat";
    options = [
      "nofail"
      "noauto"  # ← THE PROBLEM
    ];
  };
  "/" = {
    device = "/dev/disk/by-label/${config.sdImage.rootVolumeLabel}";
    fsType = "ext4";
  };
};
```

The `noauto` mount option means `/boot/firmware` is **never mounted automatically at boot**.

### Why This Breaks Live Rebuilds

1. Auto-update runs: `nixos-rebuild switch --flake .#kaliunbox-rpi4`
2. extlinux bootloader needs to write new boot menu to `/boot/firmware/extlinux/extlinux.conf`
3. But `/boot/firmware` is not mounted (due to `noauto` option)
4. Bootloader write fails silently or creates incomplete/corrupt boot config
5. Next boot: extlinux can't find proper boot configuration → hangs at "starting systemd..."

### Why Image Creation Works But Rebuilds Don't

- **SD Image Creation (offline build):** Works fine because the build system directly populates the firmware partition during image creation - no mounting needed
- **Live System Rebuilds:** Fails because the bootloader runs on a live system and expects `/boot/firmware` to be mounted for writes

### Why Old Installer Approach Worked

The old installer approach worked because:

1. Installer ISO boots with installer-specific config
2. User runs `kaliunbox-install` script
3. Script runs: `nixos-install --flake /mnt/etc/nixos/kaliunbox-flake#kaliunbox`
4. Uses **`kaliunbox`** target (x86) or **`kaliunbox-aarch64`** target (ARM64)
5. These targets do NOT import the SD image module
6. Result: `/boot/firmware` has normal mount behavior on installed system

The old `installer/rpi4-image.nix` used `sd-image-aarch64-installer.nix` (installer variant), not the regular `sd-image-aarch64.nix`. The installer variant is designed for live systems.

## Debugging Attempts Made

### Attempt 1: Remove HAOS Download from Activation Script
- **Hypothesis:** Activation script downloading HAOS image was blocking boot
- **Fix:** Removed `downloadHomeAssistant` activation script from `modules/homeassistant/default.nix`
- **Result:** Didn't fix the issue, but was a legitimate improvement (network may not be ready during activation)
- **Commit:** Part of ongoing fixes

### Attempt 2: Delay Management Console with Timer
- **Hypothesis:** `management-console.service` with `wantedBy=multi-user.target` was blocking systemd startup
- **Fix:** Removed `wantedBy`, added systemd timer to start 5 seconds after boot
- **Result:** Made things WORSE - even generation 2 stopped working
- **Resolution:** Reverted in commit 78f46fd

### Attempt 3: Identify Generation Differences
- **Investigation:** Compared working gen 2 vs broken gen 3+
- **Finding:** Identical kernel, initrd, but different systemConfig paths
- **Realization:** The issue isn't in the system config content, but in how the bootloader is configured

### Final Discovery
- **Investigation:** Checked what flake target is used for rebuilds
- **Finding:** `/var/lib/kaliun/flake_target` contains `kaliunbox-rpi4`
- **Root Cause:** Using SD image flake target for live rebuilds causes `/boot/firmware` mounting issues

## The "Two Step Problem" Context

The user mentioned "we had that initially... it was an issue with pi that has this 2 step problem."

This refers to the **UX complexity** of the old installer approach, NOT a technical bug:
- **Step 1:** Boot installer, run claiming, run install script
- **Step 2:** Reboot into installed system

The switch to direct boot (commit ef0f0ca) was intended to simplify this to one step. However, the follow-up commit (dc5809a) that added flake target persistence introduced the rebuild bug by using the wrong target.

## Proposed Solution (Not Implemented)

Create a separate `rpi4-live.nix` configuration that:
1. Imports all the same modules as `rpi4-direct.nix`
2. Does **NOT** import the SD image module (`sd-image-aarch64.nix`)
3. Has proper `/boot/firmware` mount config for live system (without `noauto`)

Then update `rpi4-direct.nix:247` to write `kaliunbox-rpi4-live` instead of `kaliunbox-rpi4`.

### Example Implementation

**File: `rpi4-live.nix`**
```nix
# KaliunBox Raspberry Pi 4 Live System Configuration
# This is the config used for rebuilds AFTER the initial SD image boot
# Unlike rpi4-direct.nix, this does NOT import the SD image module
{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: {
  imports = [
    # KaliunBox system modules (the actual system, not SD image builder)
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

  # Raspberry Pi 4 specific boot configuration
  boot = {
    loader = {
      grub.enable = false;
      generic-extlinux-compatible = {
        enable = true;
        configurationLimit = 5;
      };
      timeout = 5;
    };

    kernelParams = [
      "console=ttyS0,115200"
      "console=tty1"
      "kvm-arm.mode=nvhe"
    ];

    kernelModules = ["kvm" "tun"];
  };

  # Proper filesystem config for live system (without noauto)
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
    };
    "/boot/firmware" = {
      device = "/dev/disk/by-label/FIRMWARE";
      fsType = "vfat";
      # Note: NO "noauto" option - bootloader needs to write here
      options = ["nofail"];
    };
  };

  # ... rest of config same as rpi4-direct.nix
}
```

**Update `flake.nix`:**
```nix
nixosConfigurations = {
  # ... existing configs ...

  # Raspberry Pi 4 SD card image (initial flash only)
  kaliunbox-rpi4 = mkRpi4System;

  # Raspberry Pi 4 live system (for rebuilds after first boot)
  kaliunbox-rpi4-live = nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    specialArgs = {inherit inputs;};
    modules = [
      ./rpi4-live.nix
      {nixpkgs.overlays = [self.overlays.default];}
    ];
  };
};
```

**Update `rpi4-direct.nix:247`:**
```bash
# Store the flake target for this device (Pi uses kaliunbox-rpi4-live for rebuilds)
echo "kaliunbox-rpi4-live" > "$STATE_DIR/flake_target"
```

## Key Learnings

1. **SD Image Modules Are For Image Creation Only**
   - The `sd-image*.nix` modules are designed for offline image building
   - They should NOT be included in live system configurations
   - The `noauto` mount option makes sense for image creation but breaks live bootloader updates

2. **Raspberry Pi Uses Different Bootloader**
   - x86/aarch64 VMs use systemd-boot (UEFI)
   - Raspberry Pi uses extlinux (U-Boot compatible)
   - extlinux writes boot config to `/boot/firmware/extlinux/extlinux.conf`
   - This directory MUST be mounted for bootloader updates to work

3. **Flake Target Persistence Is Critical**
   - Auto-update needs to know which flake target to use
   - Wrong target = wrong modules imported = broken system
   - Must use separate configs for image creation vs live system

4. **Silent Bootloader Failures Are Hard to Debug**
   - When `/boot/firmware` isn't mounted, bootloader writes may fail silently
   - System appears to build successfully but won't boot
   - No error messages because the build itself succeeds - only the bootloader write fails

## References

- [NixOS SD Image Module (sd-image.nix)](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/installer/sd-card/sd-image.nix)
- [NixOS SD Image ARM64 (sd-image-aarch64.nix)](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/installer/sd-card/sd-image-aarch64.nix)
- [NixOS on ARM - NixOS Wiki](https://nixos.wiki/wiki/NixOS_on_ARM)
- [Installing NixOS on Raspberry Pi - nix.dev](https://nix.dev/tutorials/nixos/installing-nixos-on-a-raspberry-pi.html)
- [NixOS Discourse: Creating UEFI aarch64 SD card image](https://discourse.nixos.org/t/how-to-create-uefi-aarch64-sd-card-image/34585)

## Git Commits Referenced

- `ef0f0ca` - Switch to direct boot RPi4 image and simplify installer
- `dc5809a` - Persist flake target for auto-updates (BUG INTRODUCED HERE)
- `fb823fb` - Align rpi4 config with x86/aarch64 settings
- `3581d37` - Improve claiming process and boot health handling for rpi4
- `78f46fd` - Revert management console timer fix (made things worse)
- `d4981d9` - Rebrand SeloraBox to KaliunBox

## Status

**Investigation:** Complete
**Solution:** Designed but not implemented
**Next Decision:** Evaluate whether Raspberry Pi support is worth maintaining vs focusing on x86 mini PCs only
