{
  config,
  pkgs,
  lib,
  ...
}: let
  newtPackage = pkgs.fosrl-newt;
in {
  # Load wireguard and tun kernel modules on host
  boot.kernelModules = ["wireguard" "tun"];

  # NixOS container for Newt agent
  containers.newt-agent = {
    autoStart = true;
    ephemeral = false;

    # Use host network for WireGuard to work properly
    privateNetwork = false;

    # Enable TUN/TAP for VPN functionality
    enableTun = true;

    # Bind mounts
    bindMounts = {
      "/var/lib/kaliun/config.json" = {
        hostPath = "/var/lib/kaliun/config.json";
        isReadOnly = true;
      };
      # Bind mount newt binary from host
      "/usr/bin/newt" = {
        hostPath = "${newtPackage}/bin/newt";
        isReadOnly = true;
      };
    };

    # Allow capabilities needed for WireGuard
    additionalCapabilities = [
      "CAP_NET_ADMIN"
      "CAP_NET_RAW"
      "CAP_NET_BIND_SERVICE"
    ];

    config = {
      config,
      pkgs,
      ...
    }: {
      system.stateVersion = "25.05";

      networking = {
        firewall.enable = false;
        nameservers = ["1.1.1.1" "8.8.8.8"];
      };

      environment.etc."resolv.conf".text = ''
        nameserver 1.1.1.1
        nameserver 8.8.8.8
      '';

      environment.systemPackages = with pkgs; [curl jq iproute2];

      systemd = {
        services = {
          # Newt agent systemd service
          newt-agent = {
            description = "Pangolin Newt Remote Access Agent";
            wantedBy = ["multi-user.target"];
            after = ["network.target"];
            wants = ["network.target"];

            startLimitBurst = 10;
            startLimitIntervalSec = 600;

            serviceConfig = {
              Type = "simple";
              Restart = "always";
              RestartSec = "30s";

              # Run as root for WireGuard access
              User = "root";

              StateDirectory = "newt";
              LogsDirectory = "newt";
              RuntimeDirectory = "newt";
              ConfigurationDirectory = "newt-client";

              Environment = "HOME=/var/lib/newt";
            };

            script = ''
              set -euo pipefail

              rm -f /var/lib/newt/health

              if [ ! -f /var/lib/kaliun/config.json ]; then
                echo "ERROR: Configuration file not found"
                exit 1
              fi

              export NEWT_ID=$(${pkgs.jq}/bin/jq -r '.pangolin.newt_id // empty' /var/lib/kaliun/config.json)
              export NEWT_SECRET=$(${pkgs.jq}/bin/jq -r '.pangolin.newt_secret // empty' /var/lib/kaliun/config.json)
              export PANGOLIN_ENDPOINT=$(${pkgs.jq}/bin/jq -r '.pangolin.endpoint // empty' /var/lib/kaliun/config.json)

              if [ -z "$NEWT_ID" ] || [ -z "$NEWT_SECRET" ] || [ -z "$PANGOLIN_ENDPOINT" ]; then
                echo "ERROR: Missing Newt configuration in config.json"
                exit 1
              fi

              if [[ ! "$PANGOLIN_ENDPOINT" =~ ^https?:// ]]; then
                export PANGOLIN_ENDPOINT="https://$PANGOLIN_ENDPOINT"
              fi

              echo "Starting Newt agent..."
              echo "  ID: $NEWT_ID"
              echo "  Endpoint: $PANGOLIN_ENDPOINT"

              exec /usr/bin/newt --health-file /var/lib/newt/health
            '';

            postStop = ''
              rm -f /var/lib/newt/health
            '';
          };

          # Health check service
          newt-health-check = {
            description = "Newt Agent Health Check";
            serviceConfig.Type = "oneshot";
            script = ''
              # This health check is meant to be informational; it should not spam failures when Newt
              # is simply not configured yet (common during early setup).
              if [ ! -f /var/lib/kaliun/config.json ]; then
                exit 0
              fi

              NEWT_ID=$(${pkgs.jq}/bin/jq -r '.pangolin.newt_id // empty' /var/lib/kaliun/config.json 2>/dev/null || echo "")
              NEWT_SECRET=$(${pkgs.jq}/bin/jq -r '.pangolin.newt_secret // empty' /var/lib/kaliun/config.json 2>/dev/null || echo "")
              PANGOLIN_ENDPOINT=$(${pkgs.jq}/bin/jq -r '.pangolin.endpoint // empty' /var/lib/kaliun/config.json 2>/dev/null || echo "")
              if [ -z "$NEWT_ID" ] || [ -z "$NEWT_SECRET" ] || [ -z "$PANGOLIN_ENDPOINT" ]; then
                # Not configured yet
                exit 0
              fi

              if systemctl is-active --quiet newt-agent.service; then
                test -f /var/lib/newt/health
              else
                exit 1
              fi
            '';
          };
        };

        timers.newt-health-check = {
          wantedBy = ["timers.target"];
          timerConfig = {
            OnBootSec = "1min";
            OnUnitActiveSec = "5min";
            Unit = "newt-health-check.service";
          };
        };
      };
    };
  };

  # Helper script on host to check Newt status
  environment.systemPackages = [
    (pkgs.writeScriptBin "newt-status" ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      if systemctl is-active --quiet container@newt-agent.service; then
        echo "Newt Container: Running"

        if ${pkgs.nixos-container}/bin/nixos-container run newt-agent -- test -f /var/lib/newt/health 2>/dev/null; then
          echo "Newt Agent: Connected"
        else
          if ${pkgs.nixos-container}/bin/nixos-container run newt-agent -- systemctl is-failed --quiet newt-agent.service 2>/dev/null; then
            echo "Newt Agent: Failed"
          else
            echo "Newt Agent: Connecting..."
          fi
        fi

        echo ""
        echo "Recent logs:"
        ${pkgs.nixos-container}/bin/nixos-container run newt-agent -- journalctl -u newt-agent -n 10 --no-pager 2>/dev/null || echo "  (logs not available)"
      else
        echo "Newt Container: Stopped"
      fi
    '')
  ];
}
