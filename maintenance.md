# SeloraBox Maintenance Commands

This document covers the maintenance commands available on SeloraBox for debugging, troubleshooting, and administration.

## Home Assistant Commands

### `ha` - Home Assistant CLI

Access the Home Assistant CLI directly from the SeloraBox host:

```bash
ha help                    # Show available commands
ha core info              # Show HA Core version and status
ha supervisor info        # Show Supervisor info
ha host info              # Show HAOS host info
ha resolution info        # Show system health issues
```

This command communicates with Home Assistant through the QEMU guest agent, allowing you to run HA CLI commands without connecting to the VM directly.

### `homeassistant-status`

Display the current status of the Home Assistant VM:

```bash
homeassistant-status
```

Shows:
- VM running state
- MAC address
- IP address (in bridge mode)
- Network mode (bridge or usermode)

### `homeassistant-console`

Get instructions for accessing the VM console:

```bash
homeassistant-console
```

Provides connection instructions based on architecture:
- x86_64: VNC access on port 5900
- aarch64: Serial console via socket

## Snapshot Management

SeloraBox uses qcow2 internal snapshots to protect your Home Assistant data before system updates.

### `havm-snapshot-list`

List all existing snapshots:

```bash
havm-snapshot-list
```

### `havm-snapshot-create`

Create a manual snapshot:

```bash
havm-snapshot-create [name]
```

If no name is provided, a timestamped name is generated automatically. The command checks disk space before creating the snapshot.

### `havm-snapshot-restore`

Restore a snapshot:

```bash
havm-snapshot-restore <snapshot-name>
```

**Note**: The VM must be stopped before restoring. Use `systemctl stop homeassistant-vm` first.

### `havm-snapshot-delete`

Delete a specific snapshot:

```bash
havm-snapshot-delete <snapshot-name>
```

### `havm-snapshot-cleanup`

Remove old snapshots, keeping only the 2 most recent:

```bash
havm-snapshot-cleanup
```

This is run automatically before system updates to manage disk space.

## Health Monitoring

### `havm-health-check`

Check if Home Assistant is responding:

```bash
havm-health-check
```

Exit codes:
- `0` - HA is healthy and responding
- `1` - HA not responding but VM is running
- `2` - VM not running (QEMU process dead)
- `3` - VM service not active

## System Updates

### `selorabox-update`

Trigger a manual system update:

```bash
selorabox-update
```

This runs the same update process that happens automatically every 30 minutes.

### `selorabox-update-logs`

Follow the auto-update service logs:

```bash
selorabox-update-logs
```

### `selorabox-rollback`

Roll back to the previous NixOS configuration:

```bash
selorabox-rollback
```

Use this if a system update causes problems. The system will reboot into the previous working configuration.

## Boot Health Check

### `selorabox-boot-health`

Check system health after boot:

```bash
selorabox-boot-health
```

This is run automatically after system updates to verify Home Assistant is accessible.

### `selorabox-mark-good`

Mark the current boot as successful:

```bash
selorabox-mark-good
```

This prevents automatic rollback on the next boot.

## SeloraHomes Services

### `selorahomes-status`

Check the status of SeloraHomes management services:

```bash
selorahomes-status
```

### `newt-status`

Check the Newt remote access container status:

```bash
newt-status
```

## Viewing Logs

All services use journald. View logs with:

```bash
# Home Assistant VM logs
journalctl -u homeassistant-vm -f

# Watchdog service
journalctl -u homeassistant-watchdog -f

# Auto-update service
journalctl -u selorahomes-auto-update -f

# Boot health check
journalctl -u selorahomes-boot-health-check -f

# Token refresh service
journalctl -u selorahomes-token-refresh -f

# Config sync service
journalctl -u selorahomes-config-sync -f

# Health reporter
journalctl -u selorahomes-health-reporter -f
```

## USB Device Management

USB devices are automatically passed through to Home Assistant with hot-plug support. No manual configuration is needed.

If a device isn't recognized:
1. Unplug and replug the device
2. Check that it's directly connected (not through an unpowered hub)
3. Restart Home Assistant from Settings > System > Restart

## Network Modes

SeloraBox automatically detects its environment and configures networking:

- **Bridge mode** (bare metal): VM gets its own IP from network DHCP
- **User mode** (nested/VM): Access via host IP on port 8123

Check current mode:
```bash
cat /var/lib/havm/network_mode
```
