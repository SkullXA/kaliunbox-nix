# Welcome message and shell configuration for KaliunBox installer
{
  pkgs,
  lib,
  ...
}: {
  # Auto-login on tty2 only (claiming service uses tty1)
  services.getty.autologinUser = lib.mkForce "root";
  systemd.services = {
    "getty@tty1".enable = false;
    "autovt@tty1".enable = false;
  };

  # Welcome message (shown on all ttys except tty1)
  programs.bash.interactiveShellInit = ''
    if [ "$(tty)" != "/dev/tty1" ]; then
      cat << 'EOF'

    ╔════════════════════════════════════════════════════════════╗
    ║          Welcome to KaliunBox Installer                    ║
    ╚════════════════════════════════════════════════════════════╝

    → tty1 (Alt+F1): Device claiming with QR code
    → tty2 (Alt+F2): Manual installer access

    Commands:
      kaliunbox-install - Run guided installation after claiming
      kaliunbox-claim   - Manually run claiming process
      nixos-install     - Manual NixOS installation

    Note: The claiming QR code is displayed on tty1 after boot.
          Switch to tty1 to see it, or wait for it to complete.

    EOF
    fi
  '';
}
