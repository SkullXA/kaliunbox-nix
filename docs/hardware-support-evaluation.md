# KaliunBox Hardware Support Evaluation

**Date:** December 26, 2025
**Status:** Strategic Decision Needed

## Current Hardware Support Matrix

| Platform | Flake Target | Build Target | Status | Complexity | Maintenance |
|----------|-------------|--------------|--------|------------|-------------|
| **x86_64** | `kaliunbox` | `installer-iso` | ✅ Production | Low | Low |
| **ARM64 (Generic)** | `kaliunbox-aarch64` | `installer-iso` | ⚠️ Testing | Medium | Medium |
| **Raspberry Pi 4** | `kaliunbox-rpi4` | `rpi4-direct` | ✅ Working | Medium | Medium |

> **Update (Dec 26, 2025):** Pi 4 boot issues have been resolved. The problem was a systemd service conflict, not the `/boot/firmware` mount issue originally suspected. See [raspberry-pi-boot-issue-investigation.md](raspberry-pi-boot-issue-investigation.md) for details.

## Current State Analysis

### ✅ x86_64 (Intel/AMD) - WORKING

**Hardware Examples:**
- Intel NUC
- Dell OptiPlex Micro
- HP EliteDesk Mini
- Lenovo ThinkCentre Tiny
- Mini PCs (Beelink, Minisforum, etc.)

**Technical Details:**
- **Bootloader:** systemd-boot (UEFI)
- **Installer:** ISO boots, runs claiming, installs to disk
- **Auto-updates:** ✅ Working perfectly
- **Home Assistant VM:** ✅ QEMU/KVM with bridge networking
- **Boot Config:** Standard UEFI, no special requirements

**Why It Works:**
- Standard x86_64 architecture
- UEFI boot is well-supported in NixOS
- systemd-boot "just works"
- No special firmware or partition requirements
- Live rebuilds work flawlessly

**Maintenance Burden:** **LOW**
- No architecture-specific hacks
- Standard NixOS configuration
- Well-documented ecosystem
- Auto-updates work without issues

**Cost Analysis:**
- New mini PC: $150-$300 (good) to $400-$600 (high-end)
- Used/refurbished: $80-$150
- Availability: Excellent - readily available everywhere

---

### ⚠️ ARM64 (Generic aarch64) - TESTING ONLY

**Hardware Examples:**
- Cloud instances (AWS Graviton, Oracle Cloud ARM)
- Developer boards (Rock Pi, Odroid)
- Some mini PCs (rare)

**Technical Details:**
- **Bootloader:** systemd-boot (UEFI where available)
- **Installer:** ISO builds, not extensively tested
- **Auto-updates:** Probably works (not confirmed)
- **Home Assistant VM:** QEMU/KVM (with ARM-specific KVM setup)

**Current Issues:**
- Not tested on real hardware
- Limited ARM64 hardware with UEFI support
- Market availability is poor
- Customer support complexity

**Maintenance Burden:** **MEDIUM**
- Architecture-specific kernel modules (`kvm-arm.mode=nvhe`)
- Less community documentation
- Potential hardware compatibility issues
- No real-world testing/validation

**Market Analysis:**
- **Consumer ARM64 devices with UEFI:** Almost nonexistent
- **Raspberry Pi:** Doesn't use UEFI (see below)
- **Cloud only:** Not suitable for home automation appliance

**Recommendation:** **Drop support** unless there's specific demand
- No clear hardware to recommend to customers
- Adds testing/support burden with no benefit
- Focus on proven x86_64 platform

---

### ✅ Raspberry Pi 4 - WORKING

**Hardware:**
- Raspberry Pi 4 (2GB/4GB/8GB RAM)
- SD card boot (U-Boot + extlinux)

**Technical Details:**
- **Bootloader:** extlinux (U-Boot compatible) - NOT systemd-boot
- **Boot Process:** GPU firmware → U-Boot → extlinux → kernel
- **Image Type:** Direct boot SD image (plug-and-play)
- **Auto-updates:** ✅ **WORKING** - extlinux.conf on root partition (always mounted)

**Previous Issues (Now Resolved):**

The original investigation incorrectly identified `/boot/firmware` mount issues as the root cause. The actual problem was:
- `conflicts = ["management-console.service"]` in the first-boot service
- This prevented management-console from auto-starting on subsequent boots
- **Fix:** Removed the `conflicts` directive from `rpi4-direct.nix`

See [raspberry-pi-boot-issue-investigation.md](raspberry-pi-boot-issue-investigation.md) for the full investigation.

**Complexity Analysis:**

| Aspect | x86_64 | Raspberry Pi 4 |
|--------|--------|----------------|
| Bootloader | systemd-boot (standard) | extlinux (custom) |
| Boot partition | Standard /boot | Firmware partition with special flags |
| Image creation | ISO (universal) | SD image (Pi-specific) |
| Configuration | Single config | Two configs needed (image + live) |
| Rebuilds | Just works | Requires special handling |
| Firmware updates | Automatic | Manual SD card reflash |
| Hardware variants | Any x86_64 | Pi 3, Pi 4, Pi 5 (all different) |
| Documentation | Excellent | Limited, community-driven |
| Market availability | Excellent | Good (but often sold out) |
| Enterprise support | Yes (Intel, AMD) | No |

**Maintenance Burden:** **MEDIUM** (Reduced from "Very High" after fixes)

1. **Single config works for both image and rebuilds:**
   - `rpi4-direct.nix` - Works for both SD image creation AND live rebuilds
   - No separate `rpi4-live.nix` needed (original hypothesis was wrong)
   - extlinux.conf is on root partition, always accessible

2. **Boot process:**
   - GPU firmware → U-Boot → extlinux (on root partition) → NixOS
   - Device tree overlays handled automatically
   - No custom firmware partition handling needed for rebuilds

3. **Testing considerations:**
   - Physical Pi hardware recommended for full testing
   - Can test most functionality on ARM64 VMs/cloud instances
   - SD card flashing only for initial deployment

4. **Version considerations:**
   - Currently targeting Pi 4 only
   - Pi 3/5 would need separate configs if supported
   - 4GB+ RAM recommended for Home Assistant VM

5. **Customer support considerations:**
   - SD card quality matters (recommend quality brands)
   - Official power supply recommended
   - Thermal throttling possible under heavy load

6. **Performance notes:**
   - 8GB RAM maximum (sufficient for basic HA setup)
   - USB 3.0 storage works well
   - KVM virtualization supported on Pi 4

**Cost Analysis:**
- Raspberry Pi 4 (4GB): $55 (when in stock)
- Raspberry Pi 4 (8GB): $75 (when in stock)
- Official power supply: $8
- Case with fan: $15
- Quality SD card (64GB): $15
- **Total:** $113-$138 (for less capable hardware than a $150 x86_64 mini PC)

**Market Reality:**
- Often out of stock due to chip shortages
- Scalpers mark up prices
- Availability is unpredictable
- Not a reliable supply chain for business

---

## Strategic Recommendations

> **Update (Dec 26, 2025):** With Pi 4 issues now resolved, the recommendation has shifted. Both x86_64 and Pi 4 are viable options.

### Option 1: x86_64 + Raspberry Pi 4 (RECOMMENDED)

**Supported Hardware:**
- Intel/AMD mini PCs (NUC, OptiPlex, EliteDesk, etc.)
- Standard x86_64 systems with UEFI

**Benefits:**
- ✅ Everything works perfectly
- ✅ Single codebase, no architecture-specific hacks
- ✅ Auto-updates reliable
- ✅ Easy to test (VMs, any x86_64 machine)
- ✅ Automated CI/CD
- ✅ Strong hardware availability
- ✅ Better performance per dollar
- ✅ Enterprise-grade hardware options
- ✅ Easier customer support

**Trade-offs:**
- ❌ No Raspberry Pi support (but Pi is problematic anyway)
- ❌ No ARM cloud instances (not relevant for home appliance)

**Recommended x86_64 Hardware for Customers:**

| Tier | Device | RAM | Storage | Price | Use Case |
|------|--------|-----|---------|-------|----------|
| Budget | Beelink Mini S12 | 16GB | 256GB | $150 | Basic home |
| Standard | Intel NUC 11 | 16GB | 512GB | $300 | Most customers |
| Premium | Dell OptiPlex 7090 Micro | 32GB | 1TB | $500 | Power users |
| Refurb | HP EliteDesk 800 G4 | 16GB | 256GB | $120 | Budget-conscious |

---

### Option 2: x86_64 + Raspberry Pi (NOT RECOMMENDED)

**Additional Work Required:**
1. Create `rpi4-live.nix` configuration
2. Implement two-config Pi system (image + live)
3. Test extensively on real hardware
4. Document Pi-specific troubleshooting
5. Support SD card issues, power problems, thermal throttling
6. Maintain separate CI pipeline for ARM builds
7. Handle Pi 3/4/5 differences
8. Keep both configs in sync for every feature

**Estimated Engineering Cost:**
- Initial fix: 8-16 hours (create rpi4-live, test, debug)
- Ongoing maintenance: 20-30% overhead on every feature
- Testing overhead: 2x (need to test both x86 and Pi)
- Support overhead: Significant (Pi has more failure modes)

**Business Case:**
- **Against:** Higher cost than x86_64 mini PCs when fully configured
- **Against:** Less performant (8GB RAM max vs 16-32GB on x86)
- **Against:** More support burden (SD cards, power, thermal issues)
- **Against:** Unreliable supply chain
- **For:** Brand recognition (people know "Raspberry Pi")
- **For:** Hobbyist appeal

**Break-even Analysis:**
- If <10% of customers specifically want Pi: **Not worth supporting**
- If >50% of customers require Pi: **Worth the investment**
- Current data: **Unknown** - no customer feedback yet

---

### Option 3: Research Alternative ARM Hardware (EXPLORATORY)

**Potential Devices:**
- Rock Pi 4/5 (better specs than Pi, less availability)
- Odroid N2+ (good specs, niche market)
- Orange Pi 5 (powerful, limited software support)

**Assessment:**
- All have similar bootloader complexity to Pi
- Even worse market availability
- Less community support
- Not worth the engineering investment

---

## Decision Matrix

| Factor | x86_64 Only | x86 + Pi | x86 + ARM64 |
|--------|-------------|----------|-------------|
| **Engineering Complexity** | ⭐ Simple | ⭐⭐⭐ Complex | ⭐⭐⭐⭐ Very Complex |
| **Maintenance Burden** | ⭐ Low | ⭐⭐⭐ High | ⭐⭐⭐⭐ Very High |
| **Testing Effort** | ⭐ Low | ⭐⭐⭐ High | ⭐⭐⭐⭐ Very High |
| **Hardware Cost** | $150-300 | $100-140 | N/A |
| **Hardware Availability** | ⭐⭐⭐⭐⭐ Excellent | ⭐⭐⭐ Good | ⭐ Poor |
| **Performance** | ⭐⭐⭐⭐⭐ Excellent | ⭐⭐⭐ Good | ⭐⭐⭐ Good |
| **Reliability** | ⭐⭐⭐⭐⭐ Excellent | ⭐⭐⭐ Good | ⭐⭐⭐ Unknown |
| **Customer Appeal** | ⭐⭐⭐⭐ High | ⭐⭐⭐⭐⭐ Very High | ⭐ Low |
| **Support Complexity** | ⭐ Simple | ⭐⭐⭐ Complex | ⭐⭐⭐⭐ Very Complex |

---

## Recommended Action Plan

### Phase 1: Simplify (Immediate)

1. **Remove ARM64 (aarch64-linux) support:**
   - Delete `kaliunbox-aarch64` from flake.nix
   - Remove aarch64-linux from `packages` and `checks`
   - Update README to reflect x86_64 only
   - Simplify CI pipeline

2. **Archive Raspberry Pi support:**
   - Move `rpi4-direct.nix` to `archive/` folder
   - Keep the investigation docs for reference
   - Document decision in ROADMAP.md
   - Remove from CI builds

3. **Update documentation:**
   - README: Focus on x86_64 mini PCs
   - Add "Recommended Hardware" section with specific models
   - Create hardware buying guide for customers
   - Document why Pi isn't supported (technical reasons, not business reasons)

### Phase 2: Market Research (1-2 weeks)

1. **Survey early customers/interest:**
   - How many specifically want/need Pi support?
   - Would they accept x86_64 mini PC instead?
   - What's their budget constraint?

2. **Competitive analysis:**
   - What does Home Assistant official hardware use? (Answer: x86_64 and Odroid)
   - What do similar products support?

3. **Make informed decision:**
   - If <20% want Pi specifically: Stay x86_64 only
   - If >50% want Pi: Invest in fixing it properly
   - Otherwise: Re-evaluate based on product/market fit

### Phase 3: Focus (Ongoing)

1. **x86_64 optimization:**
   - Test on more mini PC models
   - Create hardware compatibility list
   - Partner with mini PC vendors for discounts?
   - Optimize performance on budget hardware

2. **Feature development:**
   - Focus engineering time on features, not platform support
   - Remote access (Pangolin integration)
   - Backup/restore
   - Advanced monitoring

---

## Appendix: Technical Debt Analysis

### Current State
```
flake.nix outputs:
  - kaliunbox (x86_64)
  - kaliunbox-installer (x86_64)
  - kaliunbox-aarch64 (arm64 - UNUSED)
  - kaliunbox-installer-aarch64 (arm64 - UNUSED)
  - kaliunbox-rpi4 (pi4 - BROKEN)

Total configurations: 5
Actually working: 2 (40%)
Production-ready: 1 (20%)
```

### After Simplification
```
flake.nix outputs:
  - kaliunbox (x86_64)
  - kaliunbox-installer (x86_64)

Total configurations: 2
Actually working: 2 (100%)
Production-ready: 2 (100%)
```

**Technical Debt Removed:**
- No architecture-specific conditionals in modules
- Single bootloader implementation (systemd-boot)
- Single CI pipeline
- Simpler testing matrix
- 60% less configuration to maintain

**Engineering Time Saved:**
- ~40% less testing overhead
- ~30% faster feature development
- ~50% less documentation to maintain
- ~60% less support complexity

---

## Conclusion

**Recommendation: Support both x86_64 and Raspberry Pi 4**

**Updated Rationale (Dec 26, 2025):**
1. Pi 4 boot issues have been **resolved** - the problem was a simple systemd conflict, not architectural
2. Single `rpi4-direct.nix` config works for both image creation AND live rebuilds
3. Auto-updates work correctly on Pi (extlinux.conf is on root partition)
4. Pi offers a lower price point for budget-conscious users
5. x86_64 remains the premium option for better performance
6. Both platforms now have similar maintenance burden

**Current Platform Status:**
- ✅ **x86_64:** Production-ready, recommended for best performance
- ✅ **Raspberry Pi 4:** Working, good for budget deployments
- ⚠️ **ARM64 (Generic):** Testing only, no clear hardware recommendation

**Next Steps:**
1. ~~Archive Pi and ARM64 configs~~ Keep Pi 4 support active
2. Create hardware buying guide covering both x86_64 and Pi 4
3. Focus on feature development (Pangolin integration, etc.)
4. Consider dropping generic ARM64 support (no clear use case)

**Key Learnings:**
- The original `/boot/firmware` diagnosis was wrong
- Actual issue was a systemd service conflict (`conflicts` directive)
- Pi boot architecture: extlinux.conf lives on root partition, not firmware partition
- Always verify assumptions with actual hardware testing
