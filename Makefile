.PHONY: help iso iso-x86 system packages check fmt clean vm-start vm-stop vm-status shell test download-page

# Detect if we're on macOS and use Lima, otherwise use nix directly
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
	NIX := limactl shell nix-builder -- sh -c "cd $(CURDIR) && nix
	VM_REQUIRED := true
else
	NIX := nix
	VM_REQUIRED := false
endif

# Default target
help:
	@echo "KaliunBox Build System"
	@echo "======================"
	@echo ""
	@echo "Build targets:"
	@echo "  make iso           - Build production installer ISO (ARM64)"
	@echo "  make iso-x86       - Build production installer ISO (x86_64)"
	@echo "  make iso-dev API_URL=<url> - Build development ISO with custom API"
	@echo "  make system        - Build main system configuration"
	@echo "  make packages      - Build custom packages (fosrl-newt, qrencode-large)"
	@echo ""
	@echo "Development targets:"
	@echo "  make check         - Check flake configuration"
	@echo "  make fmt           - Format Nix code"
	@echo "  make test          - Run tests"
	@echo "  make download-page - Generate downloads page HTML for preview"
	@echo "  make clean         - Clean all build artifacts"
	@echo "  make clean-dev     - Clean only development ISO"
	@echo ""
ifeq ($(VM_REQUIRED),true)
	@echo "VM management (macOS only):"
	@echo "  make vm-start      - Start Lima build VM"
	@echo "  make vm-stop       - Stop Lima build VM"
	@echo "  make vm-status     - Show VM status"
	@echo "  make shell         - Open shell in build VM"
	@echo ""
endif
	@echo "Quick start:"
ifeq ($(VM_REQUIRED),true)
	@echo "  1. make vm-start   # Start the build VM (first time only)"
	@echo "  2. make iso        # Build the installer"
else
	@echo "  make iso           # Build the installer"
endif

# Build targets
iso: iso-production

iso-production:
ifeq ($(VM_REQUIRED),true)
	@echo "Building ARM64 installer ISO in Lima VM..."
	@limactl shell nix-builder -- sh -c "cd $(CURDIR) && nix build .#packages.aarch64-linux.installer-iso --print-build-logs"
	@echo ""
	@echo "Copying ISO from VM to host..."
	@mkdir -p dist
	@rm -f dist/kaliunbox-installer.iso
	@limactl shell nix-builder -- sh -c "cd $(CURDIR) && cp -L result/iso/*.iso dist/kaliunbox-installer.iso"
	@echo ""
	@echo "✓ ARM64 ISO built successfully (for development)!"
	@echo "  Location: $(CURDIR)/dist/kaliunbox-installer.iso"
	@ls -lh dist/kaliunbox-installer.iso
else
	@echo "Building installer ISO for native architecture..."
	@nix build .#installer-iso --print-build-logs
	@mkdir -p dist
	@rm -f dist/kaliunbox-installer.iso
	@cp -L result/iso/*.iso dist/kaliunbox-installer.iso
	@echo ""
	@echo "✓ ISO built successfully!"
	@echo "  Location: $(CURDIR)/dist/kaliunbox-installer.iso"
	@ls -lh dist/kaliunbox-installer.iso
endif

# Build x86_64 production ISO
iso-x86:
ifeq ($(VM_REQUIRED),true)
	@echo "Building x86_64 installer ISO in Lima x86 VM..."
	@if ! limactl list | grep -q nix-builder-x86; then \
		echo "Creating x86_64 Lima VM (this will take a few minutes)..."; \
		limactl start lima-nix-x86.yaml --name nix-builder-x86; \
	fi
	@limactl shell nix-builder-x86 -- sh -c "cd $(CURDIR) && nix build .#packages.x86_64-linux.installer-iso --print-build-logs"
	@echo ""
	@echo "Copying ISO from VM to host..."
	@mkdir -p dist
	@rm -f dist/kaliunbox-installer-x86.iso
	@limactl shell nix-builder-x86 -- sh -c "cd $(CURDIR) && cp -L result/iso/*.iso dist/kaliunbox-installer-x86.iso"
	@echo ""
	@echo "✓ x86_64 ISO built successfully!"
	@echo "  Location: $(CURDIR)/dist/kaliunbox-installer-x86.iso"
	@ls -lh dist/kaliunbox-installer-x86.iso
else
	@echo "Building x86_64 installer ISO..."
	@nix build .#packages.x86_64-linux.installer-iso --print-build-logs
	@mkdir -p dist
	@rm -f dist/kaliunbox-installer-x86.iso
	@cp -L result/iso/*.iso dist/kaliunbox-installer-x86.iso
	@echo ""
	@echo "✓ x86_64 ISO built successfully!"
	@echo "  Location: $(CURDIR)/dist/kaliunbox-installer-x86.iso"
	@ls -lh dist/kaliunbox-installer-x86.iso
endif

# Development ISO with custom API URL
iso-dev:
ifndef API_URL
	$(error API_URL is not set. Usage: make iso-dev API_URL=http://192.168.1.100:3000)
endif
ifeq ($(VM_REQUIRED),true)
	@echo "Building ARM64 development installer ISO in Lima VM..."
	@echo "API URL: $(API_URL)"
	@limactl shell nix-builder -- sh -c "cd $(CURDIR) && KALIUNBOX_DEV_MODE=1 KALIUNBOX_API_URL=$(API_URL) nix build .#packages.aarch64-linux.installer-iso --print-build-logs --impure"
	@echo ""
	@echo "Copying ISO from VM to host..."
	@mkdir -p dist
	@rm -f dist/kaliunbox-installer-dev.iso
	@limactl shell nix-builder -- sh -c "cd $(CURDIR) && cp -L result/iso/*.iso dist/kaliunbox-installer-dev.iso"
	@echo ""
	@echo "✓ ARM64 development ISO built successfully!"
	@echo "  Location: $(CURDIR)/dist/kaliunbox-installer-dev.iso"
	@echo "  API URL: $(API_URL)"
	@ls -lh dist/kaliunbox-installer-dev.iso
else
	@echo "Building development installer ISO..."
	@echo "API URL: $(API_URL)"
	@KALIUNBOX_DEV_MODE=1 KALIUNBOX_API_URL=$(API_URL) nix build .#installer-iso --print-build-logs --impure
	@mkdir -p dist
	@rm -f dist/kaliunbox-installer-dev.iso
	@cp -L result/iso/*.iso dist/kaliunbox-installer-dev.iso
	@echo ""
	@echo "✓ Development ISO built successfully!"
	@echo "  Location: $(CURDIR)/dist/kaliunbox-installer-dev.iso"
	@echo "  API URL: $(API_URL)"
	@ls -lh dist/kaliunbox-installer-dev.iso
endif

# Development ISO for x86_64 (for testing on PCs)
iso-dev-x86:
ifndef API_URL
	$(error API_URL is not set. Usage: make iso-dev-x86 API_URL=http://192.168.1.100:3000)
endif
ifeq ($(VM_REQUIRED),true)
	@echo "Building x86_64 development installer ISO in Lima x86 VM..."
	@echo "API URL: $(API_URL)"
	@if ! limactl list | grep -q nix-builder-x86; then \
		echo "Creating x86_64 Lima VM (this will take a few minutes)..."; \
		limactl start lima-nix-x86.yaml --name nix-builder-x86; \
	fi
	@limactl shell nix-builder-x86 -- sh -c "cd $(CURDIR) && KALIUNBOX_DEV_MODE=1 KALIUNBOX_API_URL=$(API_URL) nix build .#packages.x86_64-linux.installer-iso --print-build-logs --impure"
	@echo ""
	@echo "Copying ISO from VM to host..."
	@mkdir -p dist
	@rm -f dist/kaliunbox-installer-dev-x86.iso
	@limactl shell nix-builder-x86 -- sh -c "cd $(CURDIR) && cp -L result/iso/*.iso dist/kaliunbox-installer-dev-x86.iso"
	@echo ""
	@echo "✓ x86_64 development ISO built successfully!"
	@echo "  Location: $(CURDIR)/dist/kaliunbox-installer-dev-x86.iso"
	@echo "  API URL: $(API_URL)"
	@ls -lh dist/kaliunbox-installer-dev-x86.iso
else
	@echo "Building x86_64 development installer ISO..."
	@echo "API URL: $(API_URL)"
	@KALIUNBOX_DEV_MODE=1 KALIUNBOX_API_URL=$(API_URL) nix build .#packages.x86_64-linux.installer-iso --print-build-logs --impure
	@mkdir -p dist
	@rm -f dist/kaliunbox-installer-dev-x86.iso
	@cp -L result/iso/*.iso dist/kaliunbox-installer-dev-x86.iso
	@echo ""
	@echo "✓ x86_64 development ISO built successfully!"
	@echo "  Location: $(CURDIR)/dist/kaliunbox-installer-dev-x86.iso"
	@echo "  API URL: $(API_URL)"
	@ls -lh dist/kaliunbox-installer-dev-x86.iso
endif

system:
ifeq ($(VM_REQUIRED),true)
	@echo "Building ARM64 system configuration in Lima VM..."
	@limactl shell nix-builder -- sh -c "cd $(CURDIR) && nix build .#packages.aarch64-linux.system --print-build-logs"
else
	@echo "Building system configuration..."
	@nix build .#system --print-build-logs
endif
	@echo ""
	@echo "✓ System built successfully!"

packages:
ifeq ($(VM_REQUIRED),true)
	@echo "Building ARM64 custom packages in Lima VM..."
	@limactl shell nix-builder -- sh -c "cd $(CURDIR) && nix build .#packages.aarch64-linux.fosrl-newt .#packages.aarch64-linux.qrencode-large --print-build-logs"
else
	@echo "Building custom packages..."
	@nix build .#fosrl-newt .#qrencode-large --print-build-logs
endif
	@echo ""
	@echo "✓ Packages built successfully!"

# Development targets
check:
ifeq ($(VM_REQUIRED),true)
	@echo "Checking flake in Lima VM..."
	@limactl shell nix-builder -- sh -c "cd $(CURDIR) && nix flake check"
else
	@echo "Checking flake..."
	@nix flake check
endif

fmt:
ifeq ($(VM_REQUIRED),true)
	@echo "Formatting Nix code in Lima VM..."
	@limactl shell nix-builder -- sh -c "cd $(CURDIR) && nix fmt"
else
	@echo "Formatting Nix code..."
	@nix fmt
endif

test:
	@echo "Running tests..."
	@nix shell nixpkgs#bats nixpkgs#python3 -c bats tests/

clean:
	@echo "Cleaning build artifacts..."
	@rm -rf result result-* dist
	@echo "✓ Clean complete"

clean-dev:
	@echo "Cleaning development ISO only..."
	@rm -f dist/kaliunbox-installer-dev.iso
	@echo "✓ Development ISO removed"

# VM management (macOS only)
ifeq ($(VM_REQUIRED),true)
vm-start:
	@echo "Starting Lima build VM..."
	@if limactl list | grep -q nix-builder; then \
		limactl start nix-builder; \
	else \
		echo "Creating and starting Lima VM (this will take a few minutes)..."; \
		limactl start lima-nix.yaml --name nix-builder; \
	fi
	@echo "✓ VM started"

vm-stop:
	@echo "Stopping Lima build VM..."
	@limactl stop nix-builder
	@echo "✓ VM stopped"

vm-status:
	@limactl list

shell:
	@echo "Opening shell in build VM..."
	@limactl shell nix-builder
endif

# Generate downloads page for preview (extracts logic from .gitlab-ci.yml update-index job)
download-page:
	@echo "Generating downloads page preview..."
	@scripts/generate-download-page.sh
	@echo ""
	@echo "Preview available at: file://$(CURDIR)/dist/index.html"
	@echo "Open in browser: open dist/index.html"
