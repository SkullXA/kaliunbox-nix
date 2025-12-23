# KaliunBox Development Roadmap

## Current Status: ✅ MVP Working!

**Last Updated**: December 23, 2025

---

## 🔴 TODO / Bugs to Fix

| Priority | Item | Description |
|----------|------|-------------|
| 🔴 HIGH | **Pangolin Integration** | Create real Pangolin credentials on device claim (see Phase 1) |
| 🟡 Medium | Email Service | Configure SMTP for Gotrue Auth OR enable `GOTRUE_MAILER_AUTOCONFIRM=true` |
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

**Goal**: Allow users to access Home Assistant remotely from anywhere

---

#### 📖 What is Pangolin/Newt?

**The Problem**: Customer's KaliunBox sits behind their home router's firewall. Routers block ALL incoming connections. Without remote access, customers can only use Home Assistant when they're home.

**The Solution**: Pangolin is a reverse proxy/tunnel service. Instead of internet → KaliunBox (blocked), the KaliunBox connects OUT to Pangolin, creating a tunnel. Pangolin can then route traffic back through that tunnel.

```
WITHOUT PANGOLIN (doesn't work):
Internet ──X──► Router Firewall ──► KaliunBox
                     │
                     └── "Blocked!"

WITH PANGOLIN (works):
Internet ◄──── Pangolin Server ◄──── Outbound Tunnel ◄──── KaliunBox
                     │
                     └── "KaliunBox called me, tunnel is open!"
```

**Terms**:
| Term | Definition |
|------|------------|
| **Pangolin** | Server that receives tunnels and routes traffic (cloud or self-hosted) |
| **Newt** | Client agent on KaliunBox that creates the WireGuard tunnel |
| **Site** | One device/URL in Pangolin (1 KaliunBox = 1 site) |
| **Remote Node** | Self-hosted Pangolin server (unlimited sites) |

---

#### 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              THE INTERNET                                    │
└─────────────────────────────────────────────────────────────────────────────┘
                User visits: https://tomer-ha.pangolin.net
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        PANGOLIN SERVER                                       │
│              (app.pangolin.net OR pangolin.kaliun.com)                      │
│                                                                              │
│   • Receives HTTPS requests from users                                       │
│   • Looks up which KaliunBox owns that URL                                   │
│   • Routes traffic through WireGuard tunnel                                  │
│   • Handles SSL/TLS termination                                              │
└─────────────────────────────────────────────────────────────────────────────┘
                          ▲         │
               WireGuard  │         │  HTTPS traffic
               Tunnel     │         │  to Home Assistant
               (outbound) │         ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           KALIUNBOX (Customer's Home)                        │
│                                                                              │
│   ┌─────────────────────┐      ┌─────────────────────────────────────────┐  │
│   │   Newt Container    │      │        Home Assistant VM                │  │
│   │                     │      │                                         │  │
│   │  • Connects OUT to  │◄────►│  Port 8123                              │  │
│   │    Pangolin server  │      │  (receives proxied traffic)             │  │
│   │  • WireGuard VPN    │      │                                         │  │
│   │  • No port forward! │      └─────────────────────────────────────────┘  │
│   └─────────────────────┘                                                    │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

#### ✅ What's Already Implemented

| Component | File | Status |
|-----------|------|--------|
| Newt package | `pkgs/fosrl-newt.nix` | ✅ v1.8.0 |
| Newt container | `modules/newt-container.nix` | ✅ Runs on boot |
| Config sync | `modules/connect-sync.nix` | ✅ Fetches pangolin creds |
| Placeholder creds | Connect API | ✅ Returns dummy data |

**Current state**: Newt starts but fails because credentials are placeholders, not real Pangolin creds.

---

#### ⬜ What Needs to Be Done

| Step | Task | Location | Description |
|------|------|----------|-------------|
| 1 | Choose Pangolin deployment | Decision | Cloud (app.pangolin.net) vs Self-hosted |
| 2 | Create Pangolin API integration | Connect API | Call Pangolin API on device claim |
| 3 | Store real credentials | PostgreSQL | `pangolin_newt_id`, `pangolin_newt_secret`, `pangolin_url` |
| 4 | Configure HA trusted_proxies | KaliunBox | Trust Pangolin's proxy IP |
| 5 | Add "Access" button to dashboard | Frontend | Link to `https://{device}.pangolin.net` |
| 6 | Test end-to-end | Testing | Claim → Tunnel → Access HA remotely |

---

#### 🔀 Deployment Options

**Option A: Pangolin Cloud** (for testing)
```
Pros:                          Cons:
✅ No server to manage         ❌ 1 free site only
✅ Quick to set up             ❌ $6/site/month after that
✅ Good for development        ❌ Not scalable for production
```

**Option B: Self-Hosted Pangolin** (for production)
```
Pros:                          Cons:
✅ Unlimited devices           ❌ Need VPS ($5/month)
✅ Full control                ❌ More setup complexity
✅ Custom domain               ❌ You maintain it
✅ Cost-effective at scale
```

**Recommendation**: Start with Option A for testing, then migrate to Option B for production.

---

#### 📝 Implementation Steps (Option A - Pangolin Cloud)

**Step 1: Create Pangolin Account**
1. Go to https://app.pangolin.net
2. Sign up / create organization
3. Note your API key

**Step 2: Add Pangolin API to Connect API**
```javascript
// In kaliun-connect-api/src/index.js
// After device is claimed, call Pangolin API:

const PANGOLIN_API = 'https://api.pangolin.net';
const PANGOLIN_API_KEY = process.env.PANGOLIN_API_KEY;

// Create newt credentials
const newtResponse = await fetch(`${PANGOLIN_API}/api/v1/newt`, {
  method: 'POST',
  headers: { 'Authorization': `Bearer ${PANGOLIN_API_KEY}` },
  body: JSON.stringify({ name: `kaliun-${installId}` })
});
const { id: newt_id, secret: newt_secret } = await newtResponse.json();

// Create site (public URL)
const siteResponse = await fetch(`${PANGOLIN_API}/api/v1/sites`, {
  method: 'POST',
  headers: { 'Authorization': `Bearer ${PANGOLIN_API_KEY}` },
  body: JSON.stringify({
    name: customerName,
    newt_id: newt_id,
    target: { host: 'localhost', port: 8123 }
  })
});
const { url: pangolin_url } = await siteResponse.json();

// Store in database
await db.updateInstallation(installId, {
  pangolin_newt_id: newt_id,
  pangolin_newt_secret: newt_secret,
  pangolin_endpoint: 'https://app.pangolin.net',
  pangolin_url: pangolin_url
});
```

**Step 3: Update Dashboard**
- Show "Access Home Assistant" button when `pangolin_url` is set
- Link opens `https://{pangolin_url}` in new tab

**Step 4: Environment Variables**
```bash
# Add to Railway kaliun-connect-api service
PANGOLIN_API_KEY=your_api_key_here
PANGOLIN_ENDPOINT=https://app.pangolin.net
```

---

#### 📝 Implementation Steps (Option B - Self-Hosted)

**Step 1: Deploy Pangolin to VPS**
```bash
# On a $5/mo DigitalOcean/Vultr VPS
docker run -d \
  -p 443:443 -p 51820:51820/udp \
  -v pangolin_data:/data \
  fosrl/pangolin:latest
```

**Step 2: Configure DNS**
- Point `pangolin.kaliun.com` to VPS IP
- Point `*.pangolin.kaliun.com` to VPS IP (wildcard for device subdomains)

**Step 3: Update Connect API**
- Same as Option A, but use your own endpoint

---

#### 🎯 Success Criteria

- [ ] User claims KaliunBox
- [ ] Connect API creates Pangolin site with real credentials
- [ ] KaliunBox receives credentials via config sync
- [ ] Newt connects successfully (dashboard shows "Remote Access: Connected")
- [ ] User clicks "Access Home Assistant" → opens HA in browser
- [ ] Works from anywhere (phone on cellular, etc.)

---

| Feature | Location | Status | Description |
|---------|----------|--------|-------------|
| Pangolin account | External | ⬜ | Create account on app.pangolin.net |
| Pangolin API integration | Connect API | ⬜ | Create newt + site on claim |
| Real credentials storage | PostgreSQL | ⬜ | Store in installations table |
| Config sync update | KaliunBox | ✅ | Already fetches pangolin config |
| Newt connection | KaliunBox | ✅ | Container ready, needs real creds |
| HA trusted_proxies | KaliunBox | ✅ | Dynamic proxy config implemented |
| Dashboard button | Frontend | ⬜ | "Access Home Assistant" link |
| Remote access status | Frontend | ⬜ | Show connected/disconnected |

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

