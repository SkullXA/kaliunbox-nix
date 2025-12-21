# SeloraBox Updates

## How Updates Work

SeloraBox has two independent update systems that work together to keep your system secure and up-to-date:

### 1. SeloraBox System Updates (Automatic)

- **Frequency**: Every 30 minutes
- **What updates**: NixOS host system, networking, VM management
- **Safety features**:
  - Pre-update VM snapshots protect your Home Assistant data
  - Automatic rollback if the system doesn't boot properly
  - Boot health check ensures Home Assistant is accessible after updates

You don't need to do anything for system updates - they happen automatically in the background.

### 2. Home Assistant Updates (User-Controlled)

- **How to update**: Settings > System > Updates in Home Assistant
- **What updates**: Home Assistant Core, Supervisor, Add-ons
- **Recommendation**: Follow standard Home Assistant update practices

Update Home Assistant when you're ready, just like you would on any other Home Assistant installation.

## Safety Features

### VM Snapshots

Before each SeloraBox system update, a snapshot of your Home Assistant VM is created. This protects your configuration and data in case anything goes wrong during an update.

### Watchdog

SeloraBox continuously monitors Home Assistant health and will automatically restart the VM if it becomes unresponsive. This ensures your smart home stays running even if Home Assistant encounters an issue.

### Boot Health Check

After system updates, SeloraBox verifies that Home Assistant is accessible. If Home Assistant doesn't come up properly, the system automatically rolls back to the previous working configuration.

## USB Device Support

USB devices like Zigbee coordinators (e.g., Sonoff ZBDongle-P, ConBee II) and Z-Wave sticks are automatically passed through to Home Assistant.

- **Plug and play**: Just connect your USB device and it will be available in Home Assistant
- **Hot-plug support**: Devices can be connected or disconnected while the system is running
- **Automatic detection**: No configuration needed - devices are detected and passed through automatically

## Troubleshooting

### Home Assistant is not accessible

1. Wait a few minutes - Home Assistant may be starting up after an update
2. The watchdog will automatically restart the VM if it's unresponsive
3. Check if the SeloraBox is powered on and connected to your network

### USB device not showing in Home Assistant

1. Unplug and replug the USB device
2. Check that the device is directly connected to SeloraBox (not through an unpowered hub)
3. Restart Home Assistant from Settings > System > Restart
