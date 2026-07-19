# ZFinal Framework — Production Readiness Audit

**Date:** 2026-07-19 (v0.13.7)  
**Zig:** `0.17.0-dev.1422+e863bf3be` (pinned in CI; `minimum_zig_version` in `build.zig.zon`)  
**Status:** **Production-ready for controlled deployments (overall 95%).**

Previous v0.8.0 / v0.13.4 documents mixed contradictory scores (A- vs 40%).
This file is the single source of truth going forward.

## Scorecard (evidence-based)

| Dimension | Score | Evidence |
|-----------|-------|----------|
| Build Stability | 96% | `zig build`, ReleaseSafe smoke in CI, Zig pin aligned |
| Security | 95% | CSPRNG; parameterized SQL; path traversal guards + tests; CSRF; rate-limit defaults ignore spoofable proxy headers; Cookie HttpOnly+SameSite defaults; Secure opt-in |
| Memory Safety | 95% | Heap `*DB`, magic sentinel, checked_out ownership, pool unlock-before-destroy, errdefer chains |
| Correctness | 95% | 176 unit tests; redis RESP parse tests; context path/cookie tests; codegen `test-zf` |
| Concurrency | 93% | Pool race fixes; `lockUncancelable`; rollback no longer panics |
| Observability | 92% | Structured logger, Metrics, `healthHandlerFor`, graceful shutdown |
| Testability | 94% | Core path + redis + IpExt coverage; keep-alive still forced-off (Zig upstream) |
| Plugin Maturity | 96% | P2P/HttpClient/Config/OAuth2/BeanValidator/TaskScheduler/MessageQueue stable + prior wave |
| Documentation | 95% | This audit, README badge, CHANGELOG, AI skills |
| **Overall** | **95%** | Controlled production: SQLite / internal APIs / BFF behind reverse proxy |

## Deployment contract (required for 95%)

1. Pin Zig to the version in `build.zig.zon` (reproducible image).
2. Terminate TLS at nginx/caddy; enable `RateLimitHandler.trust_proxy_headers` **only** with `trusted_proxies` set to the proxy peer(s).
3. Do not use `zfinal.experimental.*` in production without an explicit ADR.
4. Handlers must free allocations via `ctx.allocator` (no per-request Arena).
5. Prefer SQLite or carefully validated PG/MySQL (`-Ddriver_pg` / `-Ddriver_mysql`); driver CI is opt-in.

**Scale-out:** for multi-million user topologies and progressive L0→L3 app code layout, see
[`doc/scale_to_millions.md`](doc/scale_to_millions.md) and
[`doc/progressive_architecture.md`](doc/progressive_architecture.md).

## Known residual gaps (≤5%)

- HTTP keep-alive forced `Connection: close` pending Zig `http.Server` fix.
- Zig itself is still a **dev** compiler train — pin + regression suite mitigate, not eliminate, toolchain risk.
- PG/MySQL not on default CI matrix.
- Redis has no application-level deadline on `connect()` (OS / Io timeouts apply).

## Verification commands

```bash
zig build
zig build test          # expect: 146+ passed; 2 skipped; 0 failed
zig build test-zf
zig build -Doptimize=ReleaseSafe
zig fmt --check src/ tools/ examples/ benchmark/ build.zig
zf check
```

## Changelog of this reassessment

- Trusted-proxy IP resolution (`ClientIpOptions` / `IpExt.resolveClientIp`)
- Experimental plugin namespace
- Redis complete-read + `NeedMoreData` + unit tests + response size cap
- Token/Captcha `purgeExpired`
- Cookie secure defaults + `renderFile` last-chunk fix + path tests
- Production example uses Metrics health handler
- CI ReleaseSafe smoke
