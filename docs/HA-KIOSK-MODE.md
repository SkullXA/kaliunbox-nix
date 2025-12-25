# Home Assistant Kiosk Mode Design

## Overview

Add a graphical kiosk mode that displays Home Assistant's web interface on a connected display, accessible via **Alt+F3** while keeping the existing terminal-based management console on tty1.

## Current State

- **tty1**: Management console (text-based, shows system status + QR code)
- **tty2-tty6**: Available for switching (Alt+F2 through Alt+F6)
- **No graphical display server** currently running

## Proposed Architecture

### Display Server Location

The graphical environment will run on **tty3** (Alt+F3):

```
┌─────────────────────────────────────────────────────────────┐
│                    TERMINAL LAYOUT                           │
├─────────────────────────────────────────────────────────────┤
│ tty1 (Alt+F1): Management Console (existing)                │
│   └── Text-based status display + QR code                    │
│                                                              │
│ tty2 (Alt+F2): Standard login shell (existing)              │
│   └── For SSH/console access                                 │
│                                                              │
│ tty3 (Alt+F3): Home Assistant Kiosk (NEW)                   │
│   └── X11/Wayland + Chromium in fullscreen kiosk mode        │
│   └── Auto-detects HA URL and displays it                   │
│                                                              │
│ tty4-tty6: Available for future use                         │
└─────────────────────────────────────────────────────────────┘
```

### Technical Stack

#### Option 1: X11 + Chromium (Recommended)
- **Display Server**: X11 (Xorg) on tty3
- **Window Manager**: None (or minimal like `dwm`/`i3`)
- **Browser**: Chromium in kiosk mode
- **Pros**: 
  - Works on all hardware (Pi, x86, aarch64)
  - Mature, stable
  - Good hardware acceleration support
- **Cons**: 
  - Older technology
  - Slightly more resource usage

#### Option 2: Wayland + Firefox
- **Display Server**: Wayland compositor (sway/wlroots)
- **Browser**: Firefox in kiosk mode
- **Pros**:
  - Modern, better security
  - Better for Pi (lower overhead)
- **Cons**:
  - Less mature on Pi
  - Hardware acceleration varies

**Recommendation**: Start with **X11 + Chromium** for maximum compatibility.

## Implementation Details

### Module Structure

Create new module: `modules/ha-kiosk.nix`

```nix
{
  config,
  pkgs,
  lib,
  ...
}: {
  # Enable HA Kiosk mode (optional, defaults to false)
  services.ha-kiosk = {
    enable = lib.mkDefault false;
    
    # Auto-detect HA URL or use custom
    haUrl = lib.mkDefault null;  # null = auto-detect
    
    # Display settings
    tty = 3;  # Alt+F3
    resolution = "1920x1080";  # Auto-detect preferred
    
    # Browser settings
    browser = "chromium";  # or "firefox"
    kioskMode = true;
    disableScreenSaver = true;
  };
}
```

### Service Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    KIOSK SERVICE FLOW                         │
└─────────────────────────────────────────────────────────────┘

1. ha-kiosk.service starts (after multi-user.target)
   │
   ├── Condition: Display connected? (check /dev/dri/card*)
   │   └── If no display → service exits gracefully
   │
   ├── Start X server on tty3
   │   └── Xorg :0 -seat seat0 vt3
   │
   ├── Wait for X to be ready
   │   └── xsetroot, xrandr available
   │
   ├── Detect Home Assistant URL
   │   ├── Check /var/lib/havm/ha-info.json
   │   ├── Try http://localhost:8123 (user-mode networking)
   │   ├── Try http://<vm-ip>:8123 (bridge networking)
   │   └── Fallback: Show "Waiting for Home Assistant..."
   │
   ├── Launch Chromium in kiosk mode
   │   └── chromium --kiosk --noerrdialogs --disable-infobars \
   │       --autoplay-policy=no-user-gesture-required \
   │       --check-for-update-interval=31536000 \
   │       "$HA_URL"
   │
   └── Monitor and restart if browser crashes
```

### Auto-Detection Logic

```bash
# Detect HA URL (from havm-info-fetcher service)
HA_URL=""
if [ -f /var/lib/havm/ha-info.json ]; then
  # Check network mode
  NETWORK_MODE=$(cat /var/lib/havm/network_mode 2>/dev/null || echo "usermode")
  
  if [ "$NETWORK_MODE" = "usermode" ]; then
    # User-mode: HA accessible via host IP
    HA_URL="http://localhost:8123"
  else
    # Bridge mode: Get VM IP from ARP table
    HAVM_MAC=$(get_havm_mac)
    HA_IP=$(ip neigh show | grep -i "$HAVM_MAC" | awk '{print $1}')
    HA_URL="http://$HA_IP:8123"
  fi
fi

# Fallback if HA not ready
if [ -z "$HA_URL" ] || ! curl -s "$HA_URL" >/dev/null; then
  HA_URL="about:blank"  # Show blank page until HA ready
fi
```

### Display Detection

```bash
# Check if display is connected
HAS_DISPLAY=false

# Check for DRM devices (modern GPUs)
if [ -d /dev/dri ] && [ -n "$(ls -A /dev/dri/card* 2>/dev/null)" ]; then
  HAS_DISPLAY=true
fi

# Check for HDMI on Pi
if [ -f /sys/class/drm/card0-HDMI-A-1/status ]; then
  HDMI_STATUS=$(cat /sys/class/drm/card0-HDMI-A-1/status)
  if [ "$HDMI_STATUS" = "connected" ]; then
    HAS_DISPLAY=true
  fi
fi

# If no display, exit gracefully
if [ "$HAS_DISPLAY" != "true" ]; then
  echo "No display detected, kiosk mode disabled"
  exit 0
fi
```

## User Experience

### Boot Sequence

```
1. System boots → tty1 shows management console
2. User connects HDMI/display
3. ha-kiosk.service detects display
4. X server starts on tty3 (background)
5. User presses Alt+F3 → Switches to kiosk mode
6. Chromium launches fullscreen with HA
```

### Switching Between Modes

- **Alt+F1**: Management console (system status)
- **Alt+F2**: Login shell (for troubleshooting)
- **Alt+F3**: Home Assistant kiosk (fullscreen HA)
- **Alt+F4-F6**: Available for future use

### Kiosk Mode Features

- **Fullscreen**: No browser UI, just HA interface
- **Auto-refresh**: If HA URL changes (network mode switch), reload
- **Crash recovery**: Browser auto-restarts if it crashes
- **Screen blanking disabled**: Display stays on
- **Touch support**: If touchscreen connected, works automatically

## Configuration Options

### Enable/Disable

```nix
# In rpi4-direct.nix or configuration.nix
services.ha-kiosk.enable = true;  # Enable kiosk mode
```

### Custom HA URL

```nix
services.ha-kiosk.haUrl = "http://192.168.1.100:8123";  # Override auto-detection
```

### Resolution

```nix
services.ha-kiosk.resolution = "1920x1080";  # Or "auto" for auto-detect
```

### Browser Choice

```nix
services.ha-kiosk.browser = "chromium";  # or "firefox"
```

## Resource Usage

### Memory
- X11 server: ~50-100MB
- Chromium: ~200-400MB (depending on HA complexity)
- **Total**: ~250-500MB additional RAM

### CPU
- Minimal when idle (just rendering HA dashboard)
- Higher when HA dashboard has animations/updates

### Storage
- Chromium package: ~200MB
- X11 packages: ~100MB
- **Total**: ~300MB additional disk space

## Compatibility

### Raspberry Pi
- ✅ **Pi 4**: Full support (HDMI output)
- ✅ **Pi 5**: Full support (HDMI output)
- ⚠️ **Pi 3**: May be slow (limited RAM/CPU)

### Mini PC (x86/aarch64)
- ✅ **All**: Works with any display output (HDMI, DisplayPort, VGA via adapter)

### Display Types
- ✅ **HDMI**: Primary use case
- ✅ **DisplayPort**: Works
- ✅ **VGA**: Via adapter
- ✅ **Touchscreen**: Auto-detected, works in kiosk mode

## Security Considerations

### Browser Isolation
- Chromium runs in kiosk mode (no user interaction except HA)
- No file system access
- No download capability
- Sandboxed from host system

### Network Access
- Only connects to Home Assistant URL
- No external browsing
- Can be restricted via firewall rules

### Display Access
- Anyone with physical access can see HA
- Consider: Lock screen timeout? (probably not for kiosk)

## Future Enhancements

### Phase 1 (MVP)
- [x] X11 + Chromium on tty3
- [x] Auto-detect HA URL
- [x] Fullscreen kiosk mode
- [x] Alt+F3 switching

### Phase 2
- [ ] Touchscreen calibration
- [ ] Rotation support (portrait mode)
- [ ] Multiple display support
- [ ] Custom splash screen while HA loads

### Phase 3
- [ ] Wayland support (better Pi performance)
- [ ] Hardware acceleration tuning
- [ ] Remote kiosk control (via Connect API)
- [ ] Scheduled display on/off

## Implementation Notes

### Where Chromium Lives

Chromium will be:
1. **Installed as system package** (via `environment.systemPackages`)
2. **Run as root** (simplest for kiosk mode, no user management needed)
3. **Launched by systemd service** (`ha-kiosk.service`)
4. **Confined to tty3** (X server on :0, display :0.0)

### Service Dependencies

```
ha-kiosk.service
├── after: multi-user.target
├── after: homeassistant-vm.service (optional - can show "waiting" page)
├── wants: network-online.target (for HA URL detection)
└── conflicts: getty@tty3.service (we own tty3)
```

### File Locations

```
/etc/nixos/modules/ha-kiosk.nix          # Module definition
/var/lib/kaliun/ha-kiosk.log             # Service logs
/var/lib/kaliun/ha-kiosk-url             # Cached HA URL
```

## Testing Strategy

1. **Pi 4 with HDMI**: Primary test platform
2. **Mini PC with DisplayPort**: Verify x86 compatibility
3. **No display connected**: Verify graceful exit
4. **HA not ready**: Verify "waiting" page
5. **Network mode switch**: Verify URL auto-update
6. **Browser crash**: Verify auto-restart

## Rollout Plan

1. **Create module** (`modules/ha-kiosk.nix`)
2. **Add to Pi config** (optional, disabled by default)
3. **Test on Pi 4**
4. **Add to x86/aarch64** (same module, works everywhere)
5. **Document in README**
6. **Enable by default** (or keep optional?)

## Questions to Resolve

1. **Enable by default?** Or opt-in via config?
   - **Recommendation**: Opt-in initially, enable by default later

2. **What if HA is on bridge network?** 
   - Auto-detect VM IP from ARP table (already have MAC detection)

3. **What if multiple displays?**
   - Start with primary display, add multi-display later

4. **Screen blanking timeout?**
   - Disable for true kiosk, or configurable timeout?

5. **Keyboard shortcuts in kiosk?**
   - Alt+F3 to exit? Or lock it down completely?

---

**Status**: Design phase - ready for implementation when needed.

