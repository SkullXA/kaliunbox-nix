# Development Environment

Development and testing happens in UTM virtual machines running on macOS (Apple Silicon).

## Architecture

The development setup is a nested VM configuration:

```
macOS Host (aarch64)
└── UTM VM running NixOS (aarch64)
    └── QEMU VM running Home Assistant OS (aarch64)
```

## Key Differences from Production

### Networking

**Development (aarch64):**
- Uses QEMU SLIRP/user-mode networking with port forwarding
- NixOS host and Home Assistant VM share the same IP address from the Mac's perspective
- Access Home Assistant at `http://<VM_IP>:8123`
- Access HA SSH add-on at `ssh root@<VM_IP> -p 22222`

**Production (x86_64):**
- Uses bridge networking with macvtap
- Home Assistant gets its own IP from the network DHCP
- The `br-haos` bridge connects the VM to the physical network

### Firewall Ports

- Port 8123 (HA web UI): Open on both architectures
- Port 22222 (SSH add-on): **Only open on aarch64 (development)**

### USB Passthrough

- Disabled on aarch64 development VMs (virtual USB devices interfere with HAOS boot)
- Enabled on x86_64 production for Zigbee/Z-Wave dongles

### VNC Console

- On aarch64 builds, VNC is available on `127.0.0.1:5900` for debugging boot issues
- Use SSH port forwarding to access: `ssh -L 5900:127.0.0.1:5900 root@<VM_IP>`

## Setting Up a Development VM

1. Install UTM on macOS
2. Create a NixOS VM using the aarch64 ISO
3. Clone the flake to `/etc/nixos/selorabox-flake`
4. Build using the aarch64 configuration:
   ```bash
   nixos-rebuild switch --flake /etc/nixos/selorabox-flake#selorabox-aarch64
   ```

## Deploying Changes

To deploy changes to a development VM:

```bash
# Copy files and rebuild
scp modules/homeassistant/*.nix root@<VM_IP>:/etc/nixos/selorabox-flake/modules/homeassistant/
ssh root@<VM_IP> 'nixos-rebuild switch --flake /etc/nixos/selorabox-flake#selorabox-aarch64'
```

## Troubleshooting

### Home Assistant not responding

1. Check VM status: `systemctl status homeassistant-vm`
2. Check QEMU process: `ps aux | grep qemu`
3. Connect via VNC to see boot progress
4. Check guest agent: `{ echo '{"execute":"guest-ping"}'; sleep 1; } | socat - UNIX-CONNECT:/var/lib/havm/qga.sock`

### Proxy setup issues

The `homeassistant-proxy-setup` service detects SLIRP networking and uses `localhost` for HA configuration:

```bash
journalctl -u homeassistant-proxy-setup -f
```

If it incorrectly detects the network mode, check QEMU args:
```bash
ps aux | grep qemu | grep -E 'netdev (user,|slirp)'
```
