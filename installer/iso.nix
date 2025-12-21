# KaliunBox Installer ISO configuration
# This module composes the installer from smaller, focused modules
{
  config,
  pkgs,
  lib,
  inputs,
  modulesPath,
  ...
}: let
  # Development mode - set via environment or default to production
  devMode = builtins.getEnv "KALIUNBOX_DEV_MODE" != "";

  flakeBundle = pkgs.runCommand "kaliunbox-flake" {} ''
    mkdir -p $out
    cp -r ${inputs.self}/. $out/
    chmod -R +w $out
    if [ ! -d $out/.git ]; then
      cd $out
      ${pkgs.git}/bin/git init
      ${pkgs.git}/bin/git config user.email "installer@kaliun.com"
      ${pkgs.git}/bin/git config user.name "KaliunBox Installer"
      ${pkgs.git}/bin/git add .
      ${pkgs.git}/bin/git commit -m "Initial commit from installer"
    fi
  '';
in {
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
    ./modules/boot.nix
    ./modules/scripts.nix
    ./modules/auto-claim.nix
    ./modules/welcome.nix
  ];

  # ISO file name
  image.fileName = lib.mkForce "kaliunbox-installer-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}.iso";

  # ISO identification
  isoImage = let
    # Get the kaliunbox system closure to include in ISO (only for production builds)
    # In dev mode, we skip pre-loading the system to avoid cross-architecture issues
    systemArch =
      if pkgs.stdenv.hostPlatform.isAarch64
      then "kaliunbox-aarch64"
      else "kaliunbox";
    kaliunboxSystem = inputs.self.nixosConfigurations.${systemArch}.config.system.build.toplevel;
  in {
    volumeID = "KALIUNBOX";
    makeEfiBootable = true;
    makeUsbBootable = true;

    appendToMenuLabel = " - KaliunBox Installer";

    # Use higher compression to reduce ISO size (x86_64 system is larger)
    squashfsCompression = "zstd -Xcompression-level 19";

    # Force GRUB instead of systemd-boot for ISO
    grubTheme = pkgs.stdenv.mkDerivation {
      name = "kaliun-grub-theme";
      src = ./grub-theme;
      installPhase = ''
        mkdir -p $out
        cp -r ./* $out/
      '';
    };

    # Include kaliunbox flake in ISO
    contents = [
      {
        source = flakeBundle;
        target = "/kaliunbox-flake";
      }
    ];

    # Include the complete kaliunbox system in the store (production only)
    # In dev mode, skip this to avoid cross-architecture issues when building
    # x86 ISOs on ARM Macs - the system will be built fresh during installation
    storeContents =
      if devMode
      then []
      else [kaliunboxSystem];
  };

  # Network configuration
  networking = {
    wireless.enable = false;
    networkmanager.enable = lib.mkForce false;
    useDHCP = true;
  };

  # Include flakes support
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    # Increase download buffer to avoid "buffer is full" warnings during large downloads
    download-buffer-size = 256 * 1024 * 1024; # 256 MiB (default is 64 MiB)
  };

  # Disable documentation in installer to save space
  documentation.enable = false;

  system.stateVersion = "25.11";
}
