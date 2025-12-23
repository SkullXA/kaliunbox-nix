{
  description = "KaliunBox - NixOS-based Home Automation Appliance";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
    nixpkgs-unstable,
    ...
  } @ inputs: let
    # Linux systems we support
    linuxSystems = ["x86_64-linux" "aarch64-linux"];

    # Systems supported for development/formatting
    supportedSystems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];

    # Helper to generate attrs for all systems
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    forLinuxSystems = nixpkgs.lib.genAttrs linuxSystems;

    # Get pkgs for a given system
    pkgsFor = system:
      import nixpkgs {
        inherit system;
        overlays = [self.overlays.default];
      };

    # Get unstable pkgs for a given system
    pkgsUnstable = system:
      import nixpkgs-unstable {
        inherit system;
      };

    # Helper to create NixOS system for a given architecture
    mkKaliunboxSystem = system:
      nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {inherit inputs;};
        modules = [
          ./configuration.nix
          ./modules/base-system.nix
          ./modules/homeassistant
          ./modules/newt-container.nix
          ./modules/management-screen.nix
          ./modules/health-reporter.nix
          ./modules/log-reporter.nix
          ./modules/auto-update.nix
          ./modules/connect-sync.nix
          ./modules/boot-health-check.nix
          ./modules/network-watchdog.nix
          # Apply custom package overlay
          {nixpkgs.overlays = [self.overlays.default];}
        ];
      };

    # Helper to create installer ISO for a given architecture
    mkInstallerSystem = system:
      nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {inherit inputs;};
        modules = [
          ./installer/iso.nix
          # Apply custom package overlay
          {nixpkgs.overlays = [self.overlays.default];}
        ];
      };
  in {
    # Custom package overlay
    overlays.default = final: prev: {
      fosrl-newt = final.callPackage ./pkgs/fosrl-newt.nix {};
      qrencode-large = final.callPackage ./pkgs/qrencode-large.nix {};
    };

    # NixOS configurations for both architectures
    nixosConfigurations = {
      # x86_64 configurations (production)
      kaliunbox = mkKaliunboxSystem "x86_64-linux";
      kaliunbox-installer = mkInstallerSystem "x86_64-linux";

      # aarch64 configurations (development/testing)
      kaliunbox-aarch64 = mkKaliunboxSystem "aarch64-linux";
      kaliunbox-installer-aarch64 = mkInstallerSystem "aarch64-linux";
    };

    # Build outputs for both Linux architectures
    packages = forLinuxSystems (
      system: let
        pkgs = pkgsFor system;
        # Use architecture-specific config names
        systemConfig =
          if system == "x86_64-linux"
          then self.nixosConfigurations.kaliunbox
          else self.nixosConfigurations.kaliunbox-aarch64;
        installerConfig =
          if system == "x86_64-linux"
          then self.nixosConfigurations.kaliunbox-installer
          else self.nixosConfigurations.kaliunbox-installer-aarch64;
      in {
        # Bootable installer ISO
        installer-iso = installerConfig.config.system.build.isoImage;

        # System closure for deployment
        system = systemConfig.config.system.build.toplevel;

        # Individual packages
        inherit (pkgs) fosrl-newt qrencode-large;
      }
    );

    # Development shell (all systems)
    devShells = forAllSystems (
      system: let
        pkgs = pkgsFor system;
        isLinux = nixpkgs.lib.hasInfix "linux" system;
        arch =
          if system == "x86_64-linux"
          then "x86_64"
          else "aarch64";
      in {
        default = pkgs.mkShell {
          buildInputs = with pkgs;
            [
              git
              curl
              jq
              # Testing
              bats
              python3
            ]
            ++ nixpkgs.lib.optionals isLinux [
              nixos-rebuild
              qrencode
            ];
          shellHook = ''
            echo "KaliunBox NixOS Development Environment"
            ${
              if isLinux
              then ''
                echo "Architecture: ${arch}"
                echo "Available commands:"
                echo "  - nixos-rebuild build --flake .#kaliunbox${
                  if system == "aarch64-linux"
                  then "-aarch64"
                  else ""
                }"
                echo "  - nix build .#installer-iso"
                ${
                  if system == "aarch64-linux"
                  then ''
                    echo ""
                    echo "Note: Building ARM64 ISO for local development/testing"
                    echo "      CI will build x86_64 version for production"
                  ''
                  else ""
                }
              ''
              else ''
                echo "Note: This is a ${system} system"
                echo "You can still edit and format Nix files on this platform."
                echo "To build Linux systems, use a Linux machine or VM."
              ''
            }
          '';
        };
      }
    );

    # Formatter for all systems
    formatter = forAllSystems (
      system: let
        pkgs = pkgsFor system;
      in
        pkgs.alejandra
    );

    # Checks for CI (both Linux architectures)
    checks = forLinuxSystems (
      system: let
        systemConfig =
          if system == "x86_64-linux"
          then self.nixosConfigurations.kaliunbox
          else self.nixosConfigurations.kaliunbox-aarch64;
        installerConfig =
          if system == "x86_64-linux"
          then self.nixosConfigurations.kaliunbox-installer
          else self.nixosConfigurations.kaliunbox-installer-aarch64;
      in {
        system-build = systemConfig.config.system.build.toplevel;
        installer-build = installerConfig.config.system.build.isoImage;
      }
    );
  };
}
