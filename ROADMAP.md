# KaliunBox Development Roadmap

## Current Status: ✅ MVP Working!

**Last Updated**: December 23, 2025

---

## 🔴 TODO / Bugs to Fix

| Priority | Item | Description |
|----------|------|-------------|
| 🟡 Medium | Email Service | Configure SMTP for Gotrue Auth OR enable `GOTRUE_MAILER_AUTOCONFIRM=true` |
| 🟢 Low | Email Registration | Currently requires email confirmation - code fix added but needs SMTP setup |
| 🟢 Low | Debug Panel | Added to Settings page - remove before production |
| 🟢 Low | Local Dev Mode | Clean up `isLocalDev` checks and localhost testing code |

Your KaliunBox is successfully:
- ✅ Claiming devices via QR code
- ✅ Installing NixOS + Home Assistant OS VM
- ✅ Reporting health metrics to Connect API
- ✅ Showing "Online" status in dashboard
- ✅ Running Home Assistant (accessible on local network)
- ✅ Secure Network Node (Newt/Pangolin VPN) connected

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        KaliunBox (NixOS)                        │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐ │
│  │   Management    │  │   Home Asst.    │  │   Newt Agent    │ │
│  │    Console      │  │   VM (HAOS)     │  │   (Container)   │ │
│  │   (tty1)        │  │   Port 8123     │  │   Pangolin VPN  │ │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘ │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                    System Services                          ││
│  │  • health-reporter (15min)  • auto-update (30min)          ││
│  │  • config-sync (hourly)     • token-refresh (daily)        ││
│  │  • network-watchdog (60s)   • boot-health-check            ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Connect API (Railway)                        │
│  • Device registration      • Health data storage               │
│  • Config distribution      • Token management                  │
│  • Pangolin integration     • Dashboard backend                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                connect.kaliun.com (Frontend)                    │
│  • Installation dashboard   • Health metrics                    │
│  • Remote access portal     • Subscription management           │
└─────────────────────────────────────────────────────────────────┘
```

---

## What's Implemented

### ✅ Phase 0: Core Infrastructure (DONE)

| Module | File | Status | Description |
|--------|------|--------|-------------|
| Base System | `base-system.nix` | ✅ | NixOS base config, DNS fallback |
| Home Assistant VM | `homeassistant/*.nix` | ✅ | QEMU VM running HAOS |
| Newt Container | `newt-container.nix` | ✅ | Pangolin VPN tunnel |
| Health Reporter | `health-reporter.nix` | ✅ | Reports metrics every 15min |
| Auto Update | `auto-update.nix` | ✅ | Git pull + nixos-rebuild |
| Config Sync | `connect-sync.nix` | ✅ | Fetches config from Connect API |
| Boot Health | `boot-health-check.nix` | ✅ | Auto-rollback on bad boots |
| Network Watchdog | `network-watchdog.nix` | ✅ | Auto-rollback if network lost |
| Management Screen | `management-screen.nix` | ✅ | Console display on tty1 |
| Installer | `installer/*.nix` | ✅ | USB installer with claiming |

---

## Roadmap: Features to Implement

### 🔵 Phase 1: Remote Access (Priority: HIGH)

**Goal**: Allow users to access Home Assistant remotely via `connect.kaliun.com`

| Feature | Location | Status | Description |
|---------|----------|--------|-------------|
| Pangolin Remote URL | Connect API | ⬜ | Generate unique URL per device |
| HA Proxy Config | KaliunBox | ⬜ | Configure HA trusted_proxies dynamically |
| Remote Access Portal | Frontend | ⬜ | "Access Home Assistant" button |
| SSL Termination | Pangolin | ⬜ | HTTPS for remote connections |

**Implementation Notes**:
- Newt is already running and connected
- Need to configure Pangolin targets (site → HA port 8123)
- Dashboard shows "Remote Access: Not configured"

---

### 🔵 Phase 2: Notification Center

**Goal**: Real-time notifications for device events (like Selora's Notification_Center.png)

| Feature | Location | Status | Description |
|---------|----------|--------|-------------|
| Event Types | KaliunBox | ⬜ | Update started/completed, HA restart, errors |
| Event Reporting | KaliunBox | ⬜ | POST events to Connect API |
| Notification Store | Connect API | ⬜ | Store/retrieve notifications |
| Notification UI | Frontend | ⬜ | Bell icon with notification list |
| Read/Dismiss | Frontend | ⬜ | Mark notifications as read |

**Event Types to Implement**:
- `system.update.started` - Auto-update began
- `system.update.completed` - Update finished successfully
- `system.update.failed` - Update failed
- `system.rollback` - System rolled back
- `ha.restart` - Home Assistant restarted
- `ha.offline` - Home Assistant became unreachable
- `ha.online` - Home Assistant came back online
- `network.failed` - Network connectivity lost
- `network.restored` - Network connectivity restored

---

### 🔵 Phase 3: Backup & Restore

**Goal**: Automated Home Assistant backups with restore capability

| Feature | Location | Status | Description |
|---------|----------|--------|-------------|
| Scheduled Backups | KaliunBox | ⬜ | Daily/weekly HA backups |
| Backup Upload | KaliunBox | ⬜ | Upload to cloud storage |
| Backup List UI | Frontend | ⬜ | Show available backups |
| Restore Trigger | Frontend | ⬜ | One-click restore |
| Restore Execution | KaliunBox | ⬜ | Download and apply backup |

---

### 🔵 Phase 4: Remote Commands

**Goal**: Execute commands on device from dashboard

| Feature | Location | Status | Description |
|---------|----------|--------|-------------|
| Command Queue | Connect API | ⬜ | Queue commands for device |
| Command Polling | KaliunBox | ⬜ | Check for pending commands |
| Command Execution | KaliunBox | ⬜ | Execute and report results |
| Command UI | Frontend | ⬜ | Reboot, update, restart HA |

**Commands to Support**:
- `reboot` - Reboot KaliunBox
- `update` - Trigger manual update
- `restart_ha` - Restart Home Assistant
- `rollback` - Rollback to previous generation

---

### 🔵 Phase 5: Advanced Monitoring

**Goal**: Detailed device insights and alerting

| Feature | Location | Status | Description |
|---------|----------|--------|-------------|
| Historical Metrics | Connect API | ⬜ | Store time-series data |
| Metric Graphs | Frontend | ⬜ | CPU, memory, disk over time |
| Alert Rules | Connect API | ⬜ | Define thresholds |
| Email Alerts | Connect API | ⬜ | Send alerts via email |

---

## Known Issues

### VirtualBox "Waiting for network..."
- **Issue**: Management console stuck on "Waiting for network..." in VirtualBox
- **Cause**: NAT networking in VirtualBox doesn't allow `ip route get 1.1.1.1` to work
- **Workaround**: Use Bridged Adapter networking in VirtualBox
- **Note**: Device is actually working (dashboard shows Online)

### Management Screen in Nested VM
- The management screen assumes direct console access
- In VirtualBox, the display may not refresh properly
- SSH into the VM to verify status: `ssh root@<vm-ip>`

---

## Development Commands

```bash
# Build locally
nix build .#installer-iso

# Check flake
nix flake check

# Format code
nix fmt

# Test in Lima (macOS)
limactl start lima-nix.yaml
```

---

## Connect API Endpoints

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `/api/v1/installations/{id}/config` | GET | None (bootstrap) | Get initial config |
| `/api/v1/installations/{id}/config` | DELETE | Bearer | Lock config (claimed) |
| `/api/v1/installations/{id}/config` | GET | Bearer | Sync config |
| `/api/v1/installations/{id}/health` | POST | Bearer | Report health |
| `/api/v1/token/refresh` | POST | Refresh | Get new access token |

---

## File Structure

```
kaliunbox-nix/
├── configuration.nix      # Main NixOS config
├── flake.nix              # Nix flake definition
├── modules/
│   ├── base-system.nix    # Base system config
│   ├── auto-update.nix    # Auto-update service
│   ├── boot-health-check.nix
│   ├── connect-sync.nix   # Config sync with API
│   ├── health-reporter.nix
│   ├── management-screen.nix
│   ├── network-watchdog.nix
│   ├── newt-container.nix # Pangolin VPN
│   └── homeassistant/
│       ├── config.nix     # HA VM config
│       ├── networking.nix # Bridge/NAT setup
│       ├── proxy-setup.nix
│       ├── scripts.nix    # ha, havm-exec commands
│       ├── vm-service.nix # QEMU service
│       └── watchdog.nix   # HA health monitor
├── installer/
│   ├── iso.nix            # ISO build config
│   ├── claiming/
│   │   └── claim-script.sh
│   └── modules/
│       └── auto-claim.nix
└── pkgs/
    └── fosrl-newt.nix     # Newt package (v1.8.0)
```

---

## Recent Changes (Dec 23, 2025)

### Connect API v2 - Supabase Integration
- ✅ **Supabase backend** - PostgreSQL database with auth
- ✅ **Real user/password authentication** - No more magic links only
- ✅ **Google & GitHub OAuth** - Social login via Supabase Auth
- ✅ **Detailed installation dashboard** - Like Selora's with full metrics
- ✅ **Health data visualization** - Memory, disk, load average with progress bars
- ✅ **Log collection endpoint** - `POST /api/v1/installations/:id/logs`
- ✅ **Service status cards** - Home Assistant & Remote Access status
- ✅ **Modern UI** - Blue theme, two-column layout, proper navigation

**Supabase Stack (Railway):**
- Kong API Gateway: `kong-production-6d54.up.railway.app`
- PostgreSQL database with RLS policies
- Gotrue Auth for user management
- Supabase Studio for admin

### Remote Access Status
Currently working on **Option A: Pangolin Cloud (1 Free Site)** for testing.
Will need **Option B: Self-hosted Pangolin (Remote Node)** for production.

| Option | Status | Notes |
|--------|--------|-------|
| Option A: Pangolin Cloud | 🔄 Testing | 1 free site for development |
| Option B: Remote Node (VPS) | ⬜ TODO | Unlimited sites, $5/mo VPS |

### Applied Selora updates:
- ✅ DNS fallback (1.1.1.1, 8.8.8.8) + resolvconf
- ✅ Dynamic trusted_proxies (specific IPs, not CIDR ranges)
- ✅ IP change monitoring (updates proxy config on DHCP renewal)
- ✅ Network watchdog (auto-rollback if network breaks)
- ✅ `havm-exec` command for VM debugging
- ✅ Newt updated to v1.8.0
- ✅ Installer UX: "Press Enter to reboot"

---

## Connect API Routes (Updated)

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `/api/v1/installations/register` | POST | None | Register new device |
| `/api/v1/installations/:id/config` | GET | None/Bearer | Get config (bootstrap or sync) |
| `/api/v1/installations/:id/config` | DELETE | None | Confirm config received |
| `/api/v1/installations/:id/health` | POST | Bearer | Report health metrics |
| `/api/v1/installations/:id/logs` | POST | Bearer | **NEW** - Submit logs |
| `/api/v1/installations/token/refresh` | POST | Refresh | Get new access token |
| `/oauth/device/code` | POST | None | Start device OAuth flow |
| `/oauth/token` | POST | None | Exchange device code for token |
| `/register` | GET/POST | None | **NEW** - User registration |
| `/login` | GET/POST | None | User login with password |
| `/installations` | GET | Session | List user's installations |
| `/installations/:id` | GET | Session | **NEW** - Detailed dashboard |

