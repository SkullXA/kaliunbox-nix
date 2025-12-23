{
  config,
  pkgs,
  lib,
  ...
}: let
  kaliunLib = import ./lib.nix {inherit pkgs;};
  inherit (kaliunLib) havmMacScript;

  healthScript = pkgs.writeScriptBin "kaliun-health" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    CONFIG_FILE="/var/lib/kaliun/config.json"
    INSTALL_ID=$(cat /var/lib/kaliun/install_id 2>/dev/null || echo "unknown")
    CONNECT_API_URL=$(cat /var/lib/kaliun/connect_api_url 2>/dev/null || echo "https://kaliun-connect-api-production.up.railway.app")

    if [ ! -f "$CONFIG_FILE" ]; then
      echo "ERROR: Configuration file not found"
      exit 1
    fi

    AUTH_TOKEN=$(${pkgs.jq}/bin/jq -r '.auth.access_token // empty' "$CONFIG_FILE")

    if [ -z "$AUTH_TOKEN" ]; then
      echo "ERROR: No auth token in configuration"
      exit 1
    fi

    echo "Collecting system health metrics..."

    # Uptime in seconds
    UPTIME_SECONDS=$(${pkgs.coreutils}/bin/cat /proc/uptime | ${pkgs.gawk}/bin/awk '{print int($1)}')

    # Memory usage
    MEM_TOTAL=$(${pkgs.gnugrep}/bin/grep MemTotal /proc/meminfo | ${pkgs.gawk}/bin/awk '{print $2 * 1024}')
    MEM_AVAILABLE=$(${pkgs.gnugrep}/bin/grep MemAvailable /proc/meminfo | ${pkgs.gawk}/bin/awk '{print $2 * 1024}')
    MEM_USED=$((MEM_TOTAL - MEM_AVAILABLE))

    # Load average (1, 5, 15 min)
    LOAD_1=$(${pkgs.coreutils}/bin/cat /proc/loadavg | ${pkgs.gawk}/bin/awk '{print $1}')
    LOAD_5=$(${pkgs.coreutils}/bin/cat /proc/loadavg | ${pkgs.gawk}/bin/awk '{print $2}')
    LOAD_15=$(${pkgs.coreutils}/bin/cat /proc/loadavg | ${pkgs.gawk}/bin/awk '{print $3}')

    # Disk usage - root partition
    ROOT_USED=$(${pkgs.coreutils}/bin/df -B1 / | ${pkgs.gawk}/bin/awk 'NR==2 {print $3}')
    ROOT_TOTAL=$(${pkgs.coreutils}/bin/df -B1 / | ${pkgs.gawk}/bin/awk 'NR==2 {print $2}')

    # HA VM qcow2 disk info (virtual disk size and actual usage)
    QCOW2_FILE="/var/lib/kaliun/home-assistant.qcow2"
    HA_DISK_USED=0
    HA_DISK_TOTAL=0
    if [ -f "$QCOW2_FILE" ]; then
      QEMU_IMG_INFO=$(${pkgs.qemu}/bin/qemu-img info --force-share --output=json "$QCOW2_FILE" 2>/dev/null || echo "{}")
      HA_DISK_USED=$(echo "$QEMU_IMG_INFO" | ${pkgs.jq}/bin/jq -r '."actual-size" // 0')
      HA_DISK_TOTAL=$(echo "$QEMU_IMG_INFO" | ${pkgs.jq}/bin/jq -r '."virtual-size" // 0')
    fi

    # System info - NixOS generation
    CURRENT_GEN=$(readlink /nix/var/nix/profiles/system | ${pkgs.gnused}/bin/sed 's/.*-\([0-9]*\)-link/\1/')
    GEN_DATE=$(${pkgs.coreutils}/bin/stat -c %Y /nix/var/nix/profiles/system 2>/dev/null || echo "")
    if [ -n "$GEN_DATE" ]; then
      GEN_DATE=$(${pkgs.coreutils}/bin/date -u -d "@$GEN_DATE" +%Y-%m-%dT%H:%M:%SZ)
    fi

    # Flake revision
    FLAKE_REV=""
    if [ -f /etc/nixos/kaliunbox-flake/.git/HEAD ]; then
      FLAKE_REV=$(cd /etc/nixos/kaliunbox-flake && ${pkgs.git}/bin/git rev-parse HEAD 2>/dev/null || echo "")
    fi

    # NixOS version and arch
    NIXOS_VERSION=$(${pkgs.coreutils}/bin/cat /etc/os-release | ${pkgs.gnugrep}/bin/grep VERSION_ID | ${pkgs.coreutils}/bin/cut -d= -f2 | ${pkgs.coreutils}/bin/tr -d '"')
    ARCH=$(${pkgs.coreutils}/bin/uname -m)
    if [ "$ARCH" = "x86_64" ]; then
      ARCH="x86_64-linux"
    elif [ "$ARCH" = "aarch64" ]; then
      ARCH="aarch64-linux"
    fi

    # Updates info
    LAST_CHECK=""
    LAST_CHECK_RESULT="unknown"
    LAST_REBUILD=""
    LAST_REBUILD_RESULT="unknown"

    if [ -f /var/lib/kaliun/last_update_check ]; then
      LAST_CHECK_TS=$(${pkgs.coreutils}/bin/stat -c %Y /var/lib/kaliun/last_update_check)
      LAST_CHECK=$(${pkgs.coreutils}/bin/date -u -d "@$LAST_CHECK_TS" +%Y-%m-%dT%H:%M:%SZ)
      LAST_CHECK_RESULT=$(cat /var/lib/kaliun/last_update_check 2>/dev/null || echo "unknown")
    fi

    if [ -f /var/lib/kaliun/last_rebuild ]; then
      LAST_REBUILD_TS=$(${pkgs.coreutils}/bin/stat -c %Y /var/lib/kaliun/last_rebuild)
      LAST_REBUILD=$(${pkgs.coreutils}/bin/date -u -d "@$LAST_REBUILD_TS" +%Y-%m-%dT%H:%M:%SZ)
      LAST_REBUILD_RESULT=$(cat /var/lib/kaliun/last_rebuild 2>/dev/null || echo "unknown")
    fi

    # Home Assistant status
    HA_STATUS="stopped"
    HA_IP=""
    HA_VERSION=""
    HA_OS_VERSION=""
    HA_DEVICE_COUNT="null"
    HA_INTEGRATION_COUNT="null"

    if ${pkgs.systemd}/bin/systemctl is-active --quiet homeassistant-vm.service; then
      HA_STATUS="starting"

      # Check network mode
      if [ -f /var/lib/havm/network_mode ] && [ "$(cat /var/lib/havm/network_mode)" = "usermode" ]; then
        # In usermode networking, HA is accessible on the host IP (via port forwarding)
        HA_IP=$(${pkgs.iproute2}/bin/ip route get 1.1.1.1 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $7; exit}' || echo "127.0.0.1")
        HA_API_URL="http://127.0.0.1:8123"
      else
        HAVM_MAC=$(${havmMacScript})
        HA_IP=$(${pkgs.iproute2}/bin/ip neigh show | ${pkgs.gawk}/bin/awk -v mac="$HAVM_MAC" 'BEGIN{IGNORECASE=1} tolower($5)==tolower(mac) {print $1; exit}')

        if [ -z "$HA_IP" ]; then
          GATEWAY=$(${pkgs.iproute2}/bin/ip route | ${pkgs.gawk}/bin/awk '/default/ {print $3; exit}')
          if [ -n "$GATEWAY" ]; then
            NETWORK=$(echo "$GATEWAY" | ${pkgs.gnused}/bin/sed 's/\.[0-9]*$/.0\/24/')
            HA_IP=$(${pkgs.nmap}/bin/nmap -sn -n "$NETWORK" 2>/dev/null | \
                    ${pkgs.gawk}/bin/awk -v mac="$HAVM_MAC" 'BEGIN{IGNORECASE=1} /Nmap scan report/{ip=$NF; gsub(/[()]/,"",ip)} tolower($0)~tolower(mac){print ip; exit}')
          fi
        fi
        HA_API_URL="http://$HA_IP:8123"
      fi

      # Check if HA is actually responding
      if [ -n "$HA_IP" ]; then
        # Check if HA web interface is responding (any HTTP response means it's up)
        HTTP_CODE=$(${pkgs.curl}/bin/curl -s -m 5 -o /dev/null -w "%{http_code}" "$HA_API_URL/api/" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" != "000" ]; then
          HA_STATUS="running"

          # First, try to read from cached ha-info.json (populated by info-fetcher service via QEMU Guest Agent)
          if [ -f /var/lib/havm/ha-info.json ]; then
            CACHED_INFO=$(cat /var/lib/havm/ha-info.json 2>/dev/null)
            if [ -n "$CACHED_INFO" ]; then
              HA_VERSION=$(echo "$CACHED_INFO" | ${pkgs.jq}/bin/jq -r '.data.homeassistant // empty' 2>/dev/null || echo "")
              HA_OS_VERSION=$(echo "$CACHED_INFO" | ${pkgs.jq}/bin/jq -r '.data.hassos // empty' 2>/dev/null || echo "")
            fi
          fi

          # Read device and integration counts from cached ha-metrics.json
          if [ -f /var/lib/havm/ha-metrics.json ]; then
            HA_DEVICE_COUNT=$(${pkgs.jq}/bin/jq -r '.device_count // 0' /var/lib/havm/ha-metrics.json 2>/dev/null || echo "0")
            HA_INTEGRATION_COUNT=$(${pkgs.jq}/bin/jq -r '.integration_count // 0' /var/lib/havm/ha-metrics.json 2>/dev/null || echo "0")
          fi

          # Fallback: Try to get version from /api/ endpoint
          if [ -z "$HA_VERSION" ]; then
            HA_INFO=$(${pkgs.curl}/bin/curl -s -m 5 "$HA_API_URL/api/" 2>/dev/null || echo "{}")
            HA_VERSION=$(echo "$HA_INFO" | ${pkgs.jq}/bin/jq -r '.version // empty' 2>/dev/null || echo "")
          fi

          # Fallback: Try manifest.json (always public)
          if [ -z "$HA_VERSION" ]; then
            HA_MANIFEST=$(${pkgs.curl}/bin/curl -s -m 5 "$HA_API_URL/manifest.json" 2>/dev/null || echo "{}")
            HA_VERSION=$(echo "$HA_MANIFEST" | ${pkgs.jq}/bin/jq -r '.version // empty' 2>/dev/null || echo "")
          fi

          # Fallback: Try supervisor API for Core info
          if [ -z "$HA_VERSION" ]; then
            HA_CORE_INFO=$(${pkgs.curl}/bin/curl -s -m 5 "$HA_API_URL/api/hassio/core/info" 2>/dev/null || echo "{}")
            HA_VERSION=$(echo "$HA_CORE_INFO" | ${pkgs.jq}/bin/jq -r '.data.version // empty' 2>/dev/null || echo "")
          fi

          # Fallback: Try supervisor API for OS version
          if [ -z "$HA_OS_VERSION" ]; then
            HA_OS_INFO=$(${pkgs.curl}/bin/curl -s -m 5 "$HA_API_URL/api/hassio/os/info" 2>/dev/null || echo "{}")
            HA_OS_VERSION=$(echo "$HA_OS_INFO" | ${pkgs.jq}/bin/jq -r '.data.version // empty' 2>/dev/null || echo "")
          fi
        else
          HA_STATUS="unreachable"
        fi
      else
        HA_STATUS="unreachable"
      fi
    fi

    # Newt agent health
    NEWT_HEALTHY=false

    if ${pkgs.systemd}/bin/systemctl is-active --quiet container@newt-agent.service; then
      if ${pkgs.nixos-container}/bin/nixos-container run newt-agent -- test -f /var/lib/newt/health 2>/dev/null; then
        NEWT_HEALTHY=true
      fi
    fi

    # Host IP address
    HOST_IP=$(${pkgs.iproute2}/bin/ip route get 1.1.1.1 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $7; exit}' || echo "unknown")

    # Failed systemd units (as JSON array of unit names)
    FAILED_UNITS=$(${pkgs.systemd}/bin/systemctl --failed --no-legend --plain 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $1}' | ${pkgs.jq}/bin/jq -R -s -c 'split("\n") | map(select(length > 0))')

    # Watchdog status
    WATCHDOG_FAILURES=$(cat /var/lib/havm/watchdog_failures 2>/dev/null || echo "0")
    WATCHDOG_LAST_RESTART=""
    if [ -f /var/lib/havm/watchdog_last_restart ]; then
      WATCHDOG_LAST_RESTART_TS=$(cat /var/lib/havm/watchdog_last_restart)
      if [ -n "$WATCHDOG_LAST_RESTART_TS" ] && [ "$WATCHDOG_LAST_RESTART_TS" != "0" ]; then
        WATCHDOG_LAST_RESTART=$(${pkgs.coreutils}/bin/date -u -d "@$WATCHDOG_LAST_RESTART_TS" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
      fi
    fi

    # Boot health status
    BOOT_HEALTH_STATUS=$(cat /var/lib/kaliun/boot_health_status 2>/dev/null || echo "unknown")
    KNOWN_GOOD_GEN=$(cat /var/lib/kaliun/known_good_generation 2>/dev/null || echo "")
    ROLLBACK_ATTEMPTS=$(cat /var/lib/kaliun/rollback_attempts 2>/dev/null || echo "0")

    # Network watchdog status
    NETWORK_WATCHDOG_FAILURES=$(cat /var/lib/kaliun/network_failure_count 2>/dev/null || echo "0")
    NETWORK_WATCHDOG_LAST_ROLLBACK=""
    if [ -f /var/lib/kaliun/network_watchdog_last_rollback ]; then
      NETWORK_ROLLBACK_TS=$(cat /var/lib/kaliun/network_watchdog_last_rollback)
      if [ -n "$NETWORK_ROLLBACK_TS" ] && [ "$NETWORK_ROLLBACK_TS" != "0" ]; then
        NETWORK_WATCHDOG_LAST_ROLLBACK=$(${pkgs.coreutils}/bin/date -u -d "@$NETWORK_ROLLBACK_TS" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
      fi
    fi

    # Build JSON payload
    PAYLOAD=$(${pkgs.jq}/bin/jq -n \
      --argjson uptime "$UPTIME_SECONDS" \
      --argjson mem_used "$MEM_USED" \
      --argjson mem_available "$MEM_AVAILABLE" \
      --argjson mem_total "$MEM_TOTAL" \
      --argjson load_1 "$LOAD_1" \
      --argjson load_5 "$LOAD_5" \
      --argjson load_15 "$LOAD_15" \
      --argjson root_used "$ROOT_USED" \
      --argjson root_total "$ROOT_TOTAL" \
      --argjson ha_disk_used "$HA_DISK_USED" \
      --argjson ha_disk_total "$HA_DISK_TOTAL" \
      --argjson current_gen "$CURRENT_GEN" \
      --arg gen_date "$GEN_DATE" \
      --arg flake_rev "$FLAKE_REV" \
      --arg nixos_version "$NIXOS_VERSION" \
      --arg arch "$ARCH" \
      --arg last_check "$LAST_CHECK" \
      --arg last_check_result "$LAST_CHECK_RESULT" \
      --arg last_rebuild "$LAST_REBUILD" \
      --arg last_rebuild_result "$LAST_REBUILD_RESULT" \
      --arg ha_status "$HA_STATUS" \
      --arg ha_ip "$HA_IP" \
      --arg ha_version "$HA_VERSION" \
      --arg ha_os_version "$HA_OS_VERSION" \
      --arg ha_device_count "$HA_DEVICE_COUNT" \
      --arg ha_integration_count "$HA_INTEGRATION_COUNT" \
      --argjson newt_healthy "$NEWT_HEALTHY" \
      --arg host_ip "$HOST_IP" \
      --argjson failed_units "$FAILED_UNITS" \
      --argjson watchdog_failures "$WATCHDOG_FAILURES" \
      --arg watchdog_last_restart "$WATCHDOG_LAST_RESTART" \
      --arg boot_health_status "$BOOT_HEALTH_STATUS" \
      --arg known_good_gen "$KNOWN_GOOD_GEN" \
      --argjson rollback_attempts "$ROLLBACK_ATTEMPTS" \
      --argjson network_watchdog_failures "$NETWORK_WATCHDOG_FAILURES" \
      --arg network_watchdog_last_rollback "$NETWORK_WATCHDOG_LAST_ROLLBACK" \
      '{
        uptime_seconds: $uptime,
        memory: {
          used_bytes: $mem_used,
          available_bytes: $mem_available,
          total_bytes: $mem_total
        },
        load_average: [$load_1, $load_5, $load_15],
        disk: {
          root_used_bytes: $root_used,
          root_total_bytes: $root_total,
          ha_vm_used_bytes: $ha_disk_used,
          ha_vm_total_bytes: $ha_disk_total
        },
        system: {
          current_generation: $current_gen,
          generation_date: (if $gen_date == "" then null else $gen_date end),
          flake_rev: (if $flake_rev == "" then null else $flake_rev end),
          nixos_version: $nixos_version,
          arch: $arch,
          boot_health_status: $boot_health_status,
          known_good_generation: (if $known_good_gen == "" then null else ($known_good_gen | tonumber) end),
          rollback_attempts: $rollback_attempts
        },
        updates: {
          last_check: (if $last_check == "" then null else $last_check end),
          last_check_result: $last_check_result,
          last_rebuild: (if $last_rebuild == "" then null else $last_rebuild end),
          last_rebuild_result: $last_rebuild_result
        },
        home_assistant: {
          status: $ha_status,
          ip_address: (if $ha_ip == "" then null else $ha_ip end),
          version: (if $ha_version == "" then null else $ha_version end),
          os_version: (if $ha_os_version == "" then null else $ha_os_version end),
          device_count: (if $ha_device_count == "null" then null else ($ha_device_count | tonumber) end),
          integration_count: (if $ha_integration_count == "null" then null else ($ha_integration_count | tonumber) end),
          watchdog_failures: $watchdog_failures,
          watchdog_last_restart: (if $watchdog_last_restart == "" then null else $watchdog_last_restart end)
        },
        newt_agent: {
          healthy: $newt_healthy
        },
        network: {
          host_ip: $host_ip,
          watchdog_failures: $network_watchdog_failures,
          watchdog_last_rollback: (if $network_watchdog_last_rollback == "" then null else $network_watchdog_last_rollback end)
        },
        failed_units: $failed_units
      }')

    echo "Health data collected"
    echo "Payload: $PAYLOAD"

    # Post to Connect API with retries
    ENDPOINT="$CONNECT_API_URL/api/v1/installations/$INSTALL_ID/health"
    MAX_RETRIES=3
    RETRY_DELAY=5

    for attempt in $(seq 1 $MAX_RETRIES); do
      echo "Sending health report to: $ENDPOINT (attempt $attempt/$MAX_RETRIES)..."

      # Clear any stale response file
      rm -f /tmp/health_response.json

      # Capture curl exit code separately from HTTP code
      CURL_EXIT=0
      HTTP_CODE=$(${pkgs.curl}/bin/curl -s -w "%{http_code}" -o /tmp/health_response.json \
        --connect-timeout 10 \
        --max-time 30 \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d "$PAYLOAD" \
        "$ENDPOINT" 2>&1) || CURL_EXIT=$?

      # If curl failed, set HTTP_CODE to 000
      if [ $CURL_EXIT -ne 0 ]; then
        echo "curl failed with exit code $CURL_EXIT"
        # HTTP_CODE may contain error message, set it to 000
        HTTP_CODE="000"
      fi

      if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "204" ]; then
        echo "Health report sent successfully (HTTP $HTTP_CODE)"
        exit 0
      else
        echo "Failed to send health report (HTTP $HTTP_CODE, curl exit $CURL_EXIT)"
        if [ -f /tmp/health_response.json ] && [ -s /tmp/health_response.json ]; then
          echo "Response: $(head -c 500 /tmp/health_response.json)"
        fi

        if [ $attempt -lt $MAX_RETRIES ]; then
          echo "Retrying in $RETRY_DELAY seconds..."
          sleep $RETRY_DELAY
        fi
      fi
    done

    echo "ERROR: Failed to send health report after $MAX_RETRIES attempts"
    exit 1
  '';
in {
  environment.systemPackages = [healthScript];

  systemd.services.kaliun-health-reporter = {
    description = "KaliunBox Health Reporter";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target"];
    wants = ["network-online.target"];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      RemainAfterExit = false;
    };
    script = "${healthScript}/bin/kaliun-health";
  };

  systemd.timers.kaliun-health-reporter = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "15min";
      Unit = "kaliun-health-reporter.service";
      Persistent = true;
    };
  };
}
