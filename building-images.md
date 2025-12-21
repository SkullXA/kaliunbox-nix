# Multi-Architecture Support

## Overview

SeloraBox supports both **x86_64** and **ARM64 (aarch64)** architectures as production targets:

- **x86_64-linux**: Traditional PC hardware, Intel NUCs, mini PCs
- **aarch64-linux**: ARM64 hardware (Raspberry Pi 5, ARM servers, Apple Silicon VMs)

Both architectures are built and published by CI to https://downloads.selorahomes.com/

## Target Hardware

### x86_64
- Intel NUCs
- Mini PCs (Beelink, GEEKOM, etc.)
- Any x86_64 system with UEFI boot

### ARM64 (aarch64)
- Raspberry Pi 5 (with NVMe for best performance)
- ARM servers (Ampere, AWS Graviton)
- Apple Silicon Macs (via UTM/Parallels for testing)

## Building ISOs

### On Mac (Direct Build - ARM64)

```bash
# Build ARM64 ISO directly on your Mac (fast!)
nix build .#packages.aarch64-linux.installer-iso

# Result will be at ./result/iso/selorabox-installer-*.iso
```

This is the **recommended approach for development** on Apple Silicon Macs:
- No VM overhead
- Uses native ARM64 architecture
- Fast builds using binary caches
- Test in UTM, Parallels, or other ARM64 VM software

### On Mac (Lima VM - x86_64)

```bash
# For testing x86_64 builds (slower)
limactl start lima-nix.yaml --name nix-builder
limactl shell nix-builder nix build .#packages.x86_64-linux.installer-iso
```

Only needed if you specifically need to test x86_64 builds locally.

### On Linux

```bash
# Builds for your native architecture automatically
nix build .#installer-iso

# Or explicitly:
nix build .#packages.x86_64-linux.installer-iso    # x86_64
nix build .#packages.aarch64-linux.installer-iso   # ARM64
```

### In CI

CI builds both architectures and uploads to S3:

```bash
nix build .#packages.x86_64-linux.installer-iso
nix build .#packages.aarch64-linux.installer-iso
```

ISOs are available at https://downloads.selorahomes.com/

## NixOS Configurations

The flake provides separate configurations for each architecture:

```
nixosConfigurations:
  selorabox                    # x86_64 (production)
  selorabox-installer          # x86_64 installer
  selorabox-aarch64            # ARM64 (development)
  selorabox-installer-aarch64  # ARM64 installer
```

## Packages

All packages are built for both architectures:

```bash
packages.x86_64-linux:
  - installer-iso
  - system
  - fosrl-newt
  - qrencode-large

packages.aarch64-linux:
  - installer-iso
  - system
  - fosrl-newt
  - qrencode-large
```

## Development Workflow

### Typical Mac Development Flow

1. **Edit code** on your Mac
2. **Build ARM64 ISO** directly: `nix build .#packages.aarch64-linux.installer-iso`
3. **Test in ARM VM** (UTM, Parallels, etc.)
4. **Push to GitLab**
5. **CI builds both architectures**
6. **ISOs uploaded to S3** at https://downloads.selorahomes.com/

### Why Not Cross-Compile?

You might ask: "Why not cross-compile x86_64 on Mac?"

Cross-compilation works, but:
- Many packages don't have cross-compiled binary caches
- Builds from source are slow
- More likely to hit build failures
- ARM64 ISOs test the same functionality faster

Since the NixOS configuration is architecture-agnostic, testing on ARM64 validates the same system behavior as x86_64.

## Architecture Parity

Both architectures use identical NixOS modules and configuration. The only differences are:
- Binary packages compiled for respective architecture
- Architecture-specific bootloader configuration

NixOS abstracts hardware differences, ensuring consistent behavior across platforms.

## Downloads

Production ISOs for both architectures are available at:
https://downloads.selorahomes.com/

Files (version is either a git tag or short commit SHA):
- `selorabox-<version>-x86_64.iso` - For x86_64 hardware
- `selorabox-<version>-aarch64.iso` - For ARM64 hardware
- `.sha256` checksum files for verification
