# ADR-002: OS CSPRNG for All Security-Sensitive Randomness

**Status**: Accepted
**Date**: 2026-05-12

## Context

`RandomKit` used `DefaultPrng.init(0)` — deterministic, predictable. Token, captcha, UUID generation all produced identical sequences on restart. Attackers could predict CSRF tokens.

## Decision

Replace global PRNG with OS CSPRNG. `randomBytes()` and `uuid()` use `arc4random_buf` (macOS/BSD) / `getrandom` (Linux). General-purpose methods (`randomInt`, `shuffle`) use ChaCha PRNG seeded once from OS entropy. `setTestSource()` for deterministic testing.

## Consequences

**Positive**: Tokens/captchas/UUIDs cryptographically unpredictable. CSRF secure. Session IDs random. Production-grade by default.

**Negative**: Slightly slower than PRNG for high-frequency non-security random (negligible in practice). Windows CSPRNG not yet in std (PCG fallback with TODO for BCryptGenRandom).
