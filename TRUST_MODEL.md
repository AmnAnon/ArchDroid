# ArchDroid Trust Model and Security Boundaries

## Trust Assumptions

**ArchDroid operates under explicit trust assumptions. Understanding these boundaries is critical for proper security assessment.**

### What ArchDroid Protects Against

✅ **Network Attacks**
- MITM attacks during downloads
- Compromised download mirrors
- DNS hijacking

✅ **Supply Chain Attacks** 
- Tampered rootfs archives
- Corrupted packages
- Modified checksums (with external verification)

✅ **Runtime Inconsistencies**
- Environment contamination
- Mount point corruption
- Configuration drift

✅ **Operational Errors**
- Partial installations
- Incomplete upgrades
- Resource exhaustion

### Trust Boundaries (What We Assume Is Secure)

❌ **Root Environment Trust Boundary**
- ArchDroid assumes the root environment is not compromised
- If kernel/Android system is compromised, ArchDroid cannot provide security
- This is an unavoidable limitation of chroot-based systems

❌ **Local Storage Trust**
- ArchDroid assumes local filesystem is not tampered with at kernel level
- Protection is against application-level tampering only

❌ **Time/Clock Trust**
- System assumes clock is not manipulated for replay attacks
- Log timestamps rely on system clock accuracy

### Security Model Summary

**Threat Model Coverage:**
```
Network Attackers        → PROTECTED
Mirror Compromise        → PROTECTED  
Archive Tampering        → PROTECTED
Runtime Corruption       → PROTECTED
Partial Failures         → PROTECTED

Kernel Compromise        → OUT OF SCOPE
Hardware Attacks         → OUT OF SCOPE
Physical Access          → OUT OF SCOPE
```

**Trust Chain:**
```
External Hash Verification → Checksums File → Download Integrity → Installation Validation → Runtime Enforcement
```

## External Verification Requirements

**For Production Use:**
1. Manually verify checksums file hash against external sources
2. Use signed git tags when available:
   ```bash
   git tag -s v1.0
   git verify-tag v1.0
   ```
3. Cross-reference with official documentation

**Trust Reset Capability:**
- `archdroid reset-trust` clears all accumulated state
- Forces complete re-bootstrap with fresh verification
- Use when trust chain is suspected of compromise