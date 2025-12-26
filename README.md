# KaliunBox - NixOS Edition

KaliunBox is a self-configuring home automation appliance based on NixOS, featuring automated installation, device claiming via QR code, and self-updating configuration management.

## Overview

KaliunBox provides a complete home automation solution with:

- **NixOS Base System** - Declarative, reproducible system configuration
- **Home Assistant** - Running in QEMU/KVM VM for isolation and performance
- **Remote Access** - Pangolin Newt agent for secure remote management
- **Self-Updating** - Automatic configuration updates every 30 minutes
- **Health Monitoring** - Regular health reports to Kaliun Connect API
- **Management Console** - Physical console dashboard with QR codes

## Architecture

### System Components

```
KaliunBox (NixOS Host)
├── Home Assistant VM (QEMU/KVM)
│   └── Home Assistant OS
├── Newt Agent Container (NixOS container)
│   └── Pangolin Newt remote access agent
├── Connect Sync Service (systemd timer)
│   └── Token refresh and config sync
├── Auto-Update Service (systemd timer)
├── Health Reporter (systemd timer)
└── Management Screen (tty1 console)
```

### Key Technologies

- **NixOS 25.05** - Base operating system
- **QEMU/KVM** - VM for Home Assistant OS
- **QEMU Guest Agent** - CLI access to HAOS via `ha` command
- **NixOS Containers** - Isolation for Newt agent
- **Nix Flakes** - Reproducible configuration management

## Installation

### Prerequisites

- x86_64 or ARM64 (aarch64) system with UEFI boot support
- At least 16GB RAM (8GB for HA VM + 8GB for host)
- At least 64GB storage
- Network connectivity (DHCP)

### Installation Process

1. **Download Installer ISO**
   ```bash
   # Download from GitLab CI artifacts or build locally
   nix build .#installer-iso
   ```

2. **Boot from ISO**
   - Boot the installer ISO on target hardware
   - Plymouth will display the KaliunBox logo

3. **Device Claiming**
   - The installer automatically starts the claiming process
   - A QR code will be displayed on the screen
   - Scan the QR code to claim the device at connect.kaliun.com
   - Enter customer information and configuration
   - The installer will download the configuration automatically

4. **Run Installation**
   ```bash
   kaliunbox-install
   ```
   - Follow the prompts to select installation disk
   - The installer will partition, format, and install NixOS
   - Configuration is automatically deployed

5. **Reboot**
   - Remove installation media
   - System will boot into the configured KaliunBox

## Configuration

### Directory Structure

```
/var/lib/kaliun/
├── install_id          # Unique installation identifier
├── config.json         # Device configuration (from claiming)
└── connect_api_url     # Optional: Override Connect API URL

/etc/nixos/
└── kaliunbox-flake/    # Cloned configuration repository
    ├── flake.nix
    ├── configuration.nix
    └── modules/

/var/lib/kaliun/
├── home-assistant.qcow2
└── last_pull           # Timestamp of last configuration update

Logs are available via journald:
- `journalctl -u kaliun-auto-update.service`
- `journalctl -u kaliun-health-reporter.service`
- `journalctl -u kaliun-token-refresh.service`
- `journalctl -u kaliunbox-auto-claim.service`
```

### Configuration File Format

`/var/lib/kaliun/config.json`:

```json
{
  "auth": {
    "access_token": "jwt-access-token",
    "access_expires_at": "2025-01-01T00:00:00Z",
    "refresh_token": "refresh-token",
    "refresh_expires_at": "2025-04-01T00:00:00Z"
  },
  "customer": {
    "first_name": "John",
    "last_name": "Doe",
    "email": "john@example.com"
  },
  "pangolin": {
    "newt_id": "device-unique-id",
    "newt_secret": "secret-key",
    "endpoint": "https://pangolin.net"
  }
}
```

## Management

### Console Access

- **tty1**: Management screen (auto-refresh every 30s)
- **tty2**: Shell access (Alt+F2)

### Management Commands

```bash
# System status
kaliun-status               # Display management dashboard

# Home Assistant
homeassistant-status        # Check HA VM status
homeassistant-console       # Show console access options
ha <command>                # Execute Home Assistant CLI via QEMU Guest Agent
ha info                     # Show HA system info
ha core info                # Show Home Assistant Core info
ha host reboot              # Reboot HAOS

# Newt Agent
newt-status                 # Check Newt container status

# Updates
kaliunbox-update            # Trigger manual update
kaliunbox-update-logs       # View update logs
kaliunbox-rollback          # Rollback to previous generation
```

### Home Assistant VM Console Access

The Home Assistant OS VM provides multiple access methods:

**VNC Access (graphical console):**
VNC is available on localhost:5900. To connect remotely:

```bash
# From your workstation, create SSH tunnel:
ssh -L 5900:localhost:5900 root@<kaliunbox-ip>

# Then connect with a VNC client to localhost:5900
# Note: macOS Screen Sharing requires a password. Use TigerVNC or RealVNC instead:
brew install tiger-vnc
vncviewer localhost:5900
```

**QEMU Guest Agent (CLI access):**
The `ha` command uses QEMU Guest Agent to execute commands inside the HAOS VM:

```bash
ha info              # System information
ha core info         # Home Assistant Core info
ha supervisor info   # Supervisor info
ha host reboot       # Reboot HAOS
```

**Serial Console (aarch64 only):**
On ARM64 systems, serial console is available via `homeassistant-console`.

### Web Interfaces

- **Home Assistant**: `http://<ha-vm-ip>:8123`
- **Connect Management**: `https://connect.kaliun.com/installations/<install-id>`

## Development

### Development Prerequisites

This project uses Nix flakes. You need to enable experimental features on your development system:

```bash
# Enable flakes globally (recommended)
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

Or pass flags to each command:
```bash
nix --extra-experimental-features 'nix-command flakes' build .#system
```

### Building Locally

#### Quick Start with Makefile

The project includes a Makefile that automatically handles Lima VM setup on macOS or direct Nix builds on Linux:

```bash
# See all available commands
make help

# On macOS: Start Lima VM (first time only)
make vm-start

# Build installer ISO
make iso

# Build system configuration
make system

# Build custom packages
make packages

# Development commands
make check    # Validate flake
make fmt      # Format code
make clean    # Remove build artifacts

# macOS VM management
make vm-stop     # Stop Lima VM
make vm-status   # Check VM status
make shell       # Open shell in VM
```

#### Manual Building

##### On macOS (Apple Silicon or Intel)

**Development builds (ARM64):**
You can build ARM64 ISOs directly on your Mac for local testing:

```bash
# Build ARM64 ISO for testing in an ARM VM
nix build .#packages.aarch64-linux.installer-iso

# Build other components
nix build .#packages.aarch64-linux.system
nix build .#packages.aarch64-linux.fosrl-newt
```

**Production builds (x86_64):**
For x86_64 ISOs (production), use Lima (a Linux VM):

```bash
# Install Lima (if not already installed)
brew install lima

# Start the build VM (uses lima-nix.yaml)
make vm-start
# OR manually:
limactl start lima-nix.yaml --name nix-builder

# Build x86_64 ISO in the VM
limactl shell nix-builder nix build .#packages.x86_64-linux.installer-iso

# The VM auto-mounts your project directory, so builds
# appear in ./result on your Mac
```

**Note**: Docker Desktop on macOS has compatibility issues with Nix sandboxing. Use Lima for x86_64 builds.

##### On Linux

The flake automatically detects your system architecture:

```bash
# Build system configuration (auto-detects architecture)
nix build .#nixosConfigurations.kaliunbox.config.system.build.toplevel

# Build installer ISO (builds for your current architecture)
nix build .#installer-iso

# Or explicitly specify architecture:
nix build .#packages.x86_64-linux.installer-iso    # x86_64 (production)
nix build .#packages.aarch64-linux.installer-iso   # ARM64 (development)

# Check flake
nix flake check

# Format code
nix fmt
```

### Testing in VM

```bash
# Build and run in QEMU (uses your current architecture)
nixos-rebuild build-vm --flake .#kaliunbox
./result/bin/run-kaliunbox-vm

# Or specify architecture:
nixos-rebuild build-vm --flake .#kaliunbox              # x86_64
nixos-rebuild build-vm --flake .#kaliunbox-aarch64      # ARM64
```

### Repository Structure

```
.
├── flake.nix                      # Main flake configuration
├── flake.lock                     # Locked dependency versions
├── configuration.nix              # Base system configuration
├── hardware-configuration.nix     # Generated during installation
├── Makefile                       # Build automation
├── lima-nix.yaml                  # Lima VM configuration (macOS)
├── modules/                       # NixOS modules
│   ├── auto-update.nix
│   ├── base-system.nix
│   ├── connect-sync.nix
│   ├── health-reporter.nix
│   ├── homeassistant/             # Home Assistant VM module
│   │   ├── default.nix            # Main entry point
│   │   ├── config.nix             # Configuration constants
│   │   ├── networking.nix         # Network bridge setup
│   │   ├── vm-service.nix         # QEMU VM service
│   │   ├── proxy-setup.nix        # Reverse proxy config
│   │   ├── info-fetcher.nix       # HA info fetcher service
│   │   └── scripts.nix            # CLI tools (ha, etc.)
│   ├── lib.nix
│   ├── management-screen.nix
│   └── newt-container.nix
├── installer/                     # Installer configuration
│   ├── iso.nix                    # Main ISO configuration
│   ├── modules/                   # Installer sub-modules
│   │   ├── boot.nix               # Boot/GRUB config
│   │   ├── scripts.nix            # Install scripts
│   │   ├── auto-claim.nix         # Auto-claiming service
│   │   └── welcome.nix            # Welcome message
│   └── claiming/
│       ├── claim-script.sh
│       └── plymouth-theme/
├── pkgs/                          # Custom packages
│   └── qrencode-large.nix
├── docs/                          # Documentation
│   └── ARCHITECTURE_SUPPORT.md
├── .gitlab-ci.yml                 # CI/CD pipeline
└── README.md
```

## Update Mechanism

### Automatic Updates

- Systemd timer runs every 30 minutes
- Pulls latest changes from GitLab repository
- Updates flake lock file
- Builds and switches to new configuration
- Automatic rollback on failure

### Manual Updates

```bash
# Trigger update now
kaliunbox-update

# View update logs
kaliunbox-update-logs

# Rollback if needed
kaliunbox-rollback
```

## Health Monitoring

### Metrics Collected

- System uptime
- Memory usage
- Load average
- Home Assistant status and IP
- Newt agent health
- Network information
- Update status

### Reporting

- Posted to Connect API every 15 minutes
- Endpoint: `POST /api/v1/installations/<id>/health`
- Authenticated with Bearer token from config.json

## Troubleshooting

### Common Issues

**Home Assistant not starting:**
```bash
# Check VM status
systemctl status homeassistant-vm.service

# View VM logs
journalctl -u homeassistant-vm.service

# Check VM is accessible
homeassistant-status

# Access VM console via VNC
ssh -L 5900:localhost:5900 root@<kaliunbox-ip>
# Then connect VNC client to localhost:5900
```

**Newt agent not connecting:**
```bash
# Check container status
systemctl status container@newt-agent.service

# View Newt logs
nixos-container run newt-agent -- journalctl -u newt-agent -f

# Check configuration
jq . /var/lib/kaliun/config.json
```

**Auto-update failing:**
```bash
# View update logs
journalctl -u kaliun-auto-update.service -f

# Check Git status
cd /etc/nixos/kaliunbox-flake && git status

# Manual update
kaliunbox-update
```

**Network bridge issues:**
```bash
# Check bridge status
ip link show br0

# Re-run bridge setup
systemctl restart setup-bridge.service

# Check interface assignment
bridge link show
```

### Recovery

**Boot to previous generation:**
- At boot, select previous generation from bootloader menu
- Or run: `kaliunbox-rollback`

**Reset configuration:**
```bash
# Re-clone flake repository
cd /etc/nixos
rm -rf kaliunbox-flake
git clone https://github.com/SkullXA/kaliunbox-nix.git kaliunbox-flake

# Rebuild
nixos-rebuild switch --flake /etc/nixos/kaliunbox-flake#kaliunbox
```

## CI/CD Pipeline

### GitLab CI Stages

1. **Test**
   - `flake-check` - Flake configuration validation
   - `format-check` - Alejandra code formatting verification
   - `flake-lock-check` - Flake lock file freshness check
   - `nix-lint` - Nix linting with statix

2. **Build**
   - `build-system` - System configuration build
   - `build-iso-x86_64` - x86_64 installer ISO (uploads to S3)
   - `build-iso-aarch64` - ARM64 installer ISO (uploads to S3)
   - `build-packages` - Custom packages build

3. **Deploy**
   - `update-index` - Updates downloads page on S3

**Note**: ISO builds run automatically on tags, or manually on the default branch.

### Running CI Locally

```bash
# Validate
nix flake check

# Build (production x86_64)
nix build .#packages.x86_64-linux.system
nix build .#packages.x86_64-linux.installer-iso

# Build (development ARM64)
nix build .#packages.aarch64-linux.installer-iso

# Format
nix fmt
```

## Security Considerations

- **Unprivileged containers** - Newt agent runs in unprivileged container
- **Minimal attack surface** - Only SSH and required services exposed
- **Regular updates** - Automatic security updates via auto-update
- **Secrets management** - Config file permissions set to 600
- **Network isolation** - VMs/containers isolated via bridge networking

## Contributing

### Code Style

- Use `alejandra` for formatting (run `nix fmt` or `make fmt`)
- Follow NixOS module conventions
- Document complex configurations
- Test changes in VM before committing

### Commit Messages

Follow conventional commits:
- `feat:` - New features
- `fix:` - Bug fixes
- `docs:` - Documentation changes
- `refactor:` - Code refactoring
- `test:` - Test updates
- `ci:` - CI/CD changes

## License

Proprietary - Kaliun

## Support

- **Issues**: https://github.com/SkullXA/kaliunbox-nix/issues
- **Support Email**: support@kaliun.com

