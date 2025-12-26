# KaliunBox Hardware Support Evaluation

**Date:** December 26, 2025
**Status:** Strategic Decision Needed

## Current Hardware Support Matrix

| Platform | Flake Target | Build Target | Status | Complexity | Maintenance |
|----------|-------------|--------------|--------|------------|-------------|
| **x86_64** | `kaliunbox` | `installer-iso` | ✅ Production | Low | Low |
| **ARM64 (Generic)** | `kaliunbox-aarch64` | `installer-iso` | ⚠️ Testing | Medium | Medium |
| **Raspberry Pi 4** | `kaliunbox-rpi4` | `rpi4-direct` | ❌ Broken | **High** | **High** |

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

### ❌ Raspberry Pi 4 - BROKEN (Boot Hang Bug)

**Hardware:**
- Raspberry Pi 4 (2GB/4GB/8GB RAM)
- SD card boot (no UEFI, no standard bootloader)

**Technical Details:**
- **Bootloader:** extlinux (U-Boot compatible) - NOT systemd-boot
- **Boot Process:** GPU firmware → U-Boot → extlinux → kernel
- **Installer:** Replaced with direct boot SD image
- **Auto-updates:** ❌ **BROKEN** - causes boot hang

**Known Issues (See [raspberry-pi-boot-issue-investigation.md](raspberry-pi-boot-issue-investigation.md)):**

1. **Root Cause:** SD image module sets `/boot/firmware` mount option to `noauto`
2. **Why It Breaks:** extlinux bootloader needs to write to `/boot/firmware` during rebuilds
3. **Result:** Auto-updates create broken boot config → system hangs at "starting systemd..."
4. **Workaround:** Manual boot menu selection of old generation

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

**Maintenance Burden:** **VERY HIGH**

1. **Two separate configs required:**
   - `rpi4-direct.nix` - For SD image creation
   - `rpi4-live.nix` - For live system rebuilds (needs to be created)
   - Must keep both in sync manually

2. **Boot process complexity:**
   - Custom firmware partition handling
   - extlinux configuration management
   - Device tree overlays
   - GPU firmware compatibility

3. **Testing overhead:**
   - Need physical Pi hardware for testing
   - Can't use QEMU/VMs effectively (ARM emulation is slow)
   - SD card flashing for every test iteration
   - No automated CI testing (requires real hardware)

4. **Version fragmentation:**
   - Pi 3 vs Pi 4 vs Pi 5 have different requirements
   - Firmware compatibility issues between models
   - Different RAM variants (2GB/4GB/8GB)

5. **Customer support complexity:**
   - SD card quality/corruption issues
   - Power supply problems (Pi is sensitive)
   - USB boot vs SD boot confusion
   - Thermal throttling on Pi 4

6. **Performance limitations:**
   - 8GB RAM maximum (Home Assistant VM + host needs 16GB ideally)
   - USB 3.0 bottleneck for storage
   - No PCIe for expansion (Pi 5 has one lane)

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

### Option 1: x86_64 Only (RECOMMENDED)

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

**Recommendation: Go with x86_64 only (Option 1)**

**Rationale:**
1. Pi support is broken and complex to fix
2. Pi costs almost as much as better x86_64 hardware when fully configured
3. x86_64 mini PCs are more performant, reliable, and available
4. Engineering time better spent on features than platform support
5. Can always add Pi support later if market demands it
6. ARM64 (generic) has no clear hardware recommendation for customers

**Next Steps:**
1. Archive Pi and ARM64 configs
2. Update documentation to x86_64 only
3. Create hardware buying guide
4. Focus on feature development (Phase 1 from ROADMAP.md - Pangolin integration)

**Future Consideration:**
- If 50%+ of customers specifically request Pi support
- If Pi foundation releases Pi with 16GB+ RAM and better I/O
- If market research shows strong preference for Pi
→ Re-evaluate and invest in proper two-config Pi implementation
