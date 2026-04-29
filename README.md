# ArchDroid v0.1-alpha

**Deterministic Arch Linux Runtime for Rooted Android**

Run Arch Linux on your Android device with **predictable behavior, verified installs, and safe updates** — no more broken chroot states or manual recovery.

> ⚠️ **Alpha Software** — It works. It's tested. But it needs your help to get battle-hardened on more devices. Read more below.

---

## 🚀 The Problem

Every Arch-on-Android setup eventually breaks the same way:

- Environment gets polluted by Android/Termux
- Installs fail halfway with no recovery path
- Updates silently corrupt the system
- Failures are silent and a nightmare to debug

**ArchDroid fixes this by enforcing correctness instead of adapting to brokenness.**

- Validates system state **before** execution
- Forces a clean, isolated runtime
- Installs and updates **atomically** — no partial states
- Detects **and recovers** from failures automatically

---

## ⚡ Quick Start

```bash
git clone https://github.com/AmnAnon/archdroid.git
cd archdroid

su
./archdroid bootstrap
./archdroid start
```

If bootstrap succeeds, your system is guaranteed to be in a valid state.

---

## 🧪 This is Alpha — Here's Why That's Good

ArchDroid v0.1-alpha is **functional and tested**, but we need **your help** to make it bulletproof on more devices.

### What works today
- ✅ Deterministic chroot runtime with environment isolation
- ✅ Cryptographically verified bootstrap with checksum anchors
- ✅ Atomic in-place updates with snapshot rollback
- ✅ Comprehensive doctor/verify diagnostics
- ✅ Tested under failure: process kills, corruption, resource exhaustion

### What we want to validate
- 🎯 **Device compatibility** — tested on Poco X3 Pro (SD860, Android 11+), but what about yours?
- 🎯 **Root method compatibility** — KernelSU, Magisk, APatch?
- 🎯 **Android version quirks** — SELinux policies, mount behaviors, linker quirks
- 🎯 **Performance edge cases** — slower storage, low memory, custom ROMs

### How you can help
1. **Install it** on your device
2. **Run the diagnostics**: `./archdroid doctor`
3. **Report what works and what doesn't** → open a GitHub issue with your:
   - Device model and chipset
   - Android version and ROM
   - Root method (KernelSU / Magisk / APatch)
   - Any errors from `archdroid doctor`

Every report gets us one step closer to v1.0.

---

## ⚠️ Requirements

### Hardware & Software
- **Rooted Android**: KernelSU, Magisk, or APatch
- **Architecture**: `aarch64` (ARMv8) — covers most modern devices
- **Storage**: ~2GB free space for rootfs + operations
- **Network**: HTTPS connectivity for secure downloads
- **Dependencies**: `curl`, `tar`, `sha256sum`, `jq`, `bash`

### Verified Platforms
| Device | Chipset | Android | Root | Status |
|--------|---------|---------|------|--------|
| Poco X3 Pro | Snapdragon 860 | 11+ | KernelSU | ✅ Verified |
| *Your device?* | | | | 🎯 **Test needed** |

---

## 🧠 How It Works

ArchDroid operates in a strict loop:

```
inspect → enforce → execute → verify → (repeat)
```

1. **Inspect** — validate system state and detect issues
2. **Enforce** — fix or block invalid conditions
3. **Execute** — run in a clean, controlled environment
4. **Verify** — confirm system integrity post-execution

This guarantees the system is **never** left in an unknown or partially broken state.

---

## ✨ Features

- **🔐 Secure Bootstrap** — HTTPS downloads with checksum verification and external trust anchors
- **⚡ Atomic Updates** — zero-downtime in-place updates with guaranteed rollback
- **🛡️ Failure-Tested** — validated against process kills, file corruption, resource exhaustion, and network drops
- **🔍 Comprehensive Diagnostics** — full `doctor` inspection, independent `verify`, real-time `status`
- **🧰 Complete CLI** — unified tool for all operations
- **📊 Trust Model** — explicit security boundaries documented in `TRUST_MODEL.md`

---

## 🧭 Usage

### Getting Started
```bash
./archdroid bootstrap   # First-time installation (requires root)
./archdroid start       # Enter the Arch Linux chroot
```

### Daily Operations
```bash
./archdroid status      # System health and version info
./archdroid doctor      # Comprehensive diagnostics
./archdroid verify      # Independent integrity check
./archdroid update      # Atomic system update
```

### Recovery
```bash
./archdroid reset-trust # Clear state, force fresh bootstrap
```

### Advanced
```bash
# Bypass validation to enter anyway (for debugging)
ARCHDROID_SAFE_MODE=1 ./archdroid start

# Use an alternative rootfs path
export ARCH_PATH=/data/local/arch-test
./archdroid bootstrap
```

---

## 🔐 Security Model

ArchDroid protects against **runtime inconsistency and supply-chain risks**, not full system compromise.

### ✅ Protected
- MITM attacks, DNS hijacking, compromised mirrors
- Tampered rootfs archives, corrupted packages
- Environment contamination, mount corruption
- Partial installations, incomplete upgrades
- Interrupted operations (automatic cleanup)

### ❌ Out of Scope
- Compromised root environment
- Kernel-level attacks
- Physical device access
- System clock tampering

See `TRUST_MODEL.md` for full details.

---

## 🔧 Troubleshooting

### SELinux blocks chroot
```bash
setenforce 0 && archdroid start
```
This is temporary — resets on reboot.

### "Rootfs not found"
You need to run `./archdroid bootstrap` first.

### Doctor reports failures after a fresh bootstrap
Run `archdroid doctor` again — some mounts need a warmup cycle.

### chroot fails silently
Try the manual chroot test to see the real error:
```bash
chroot /data/local/arch /bin/bash -c 'echo ok'
```

---

## 🏗️ Project Structure

```
archdroid/
├── archdroid              # Unified CLI interface
├── core/
│   ├── inspect-runtime.sh # System validation & diagnostics
│   ├── runtime.sh         # Deterministic runtime enforcement
│   ├── bootstrap.sh       # Secure bootstrap & installation
│   ├── verify.sh          # Independent verification
│   ├── atomic-update.sh   # Atomic updates with rollback
│   ├── trust-reset.sh     # Trust recovery mechanism
│   ├── versions.sh        # Version tracking
│   └── json-utils.sh      # Safe JSON parsing
├── test/
│   ├── fuzz-framework.sh       # Failure injection testing
│   └── recovery-validation.sh  # Recovery scenario validation
├── install.sh             # Quick installation helper
├── start-arch.sh          # Legacy start script
├── stop-arch.sh           # Legacy stop script
├── TRUST_MODEL.md         # Security boundaries
├── test-android-compatibility.sh # Compatibility checker
└── README.md              # This file
```

---

## 📄 License

MIT License — use it, share it, improve it.

Attribution appreciated but not required.

---

## 🙏 Contributing

- **Found a bug?** Open an issue with your device info and `doctor` output
- **Got a fix?** PRs are welcome
- **Tested on a new device?** Add it to the verified platforms table

---

*Built for reliability. Engineered for security. Tested against chaos.*

**v0.1-alpha** — *Help us make it better.*
