# ZFinal Framework — Production Readiness Audit

**Date:** 2026-07-20 (CHANGELOG **0.13.10**; highest published tag may lag)  
**Zig:** `0.17.0-dev.1422+e863bf3be` (pinned in CI; `minimum_zig_version` in `build.zig.zon`)  
**Status:** **Controlled production OK** (SQLite / reverse-proxied BFF).  
**Independent score:** **6.8 / 10** overall · **~7.5–8 / 10** when the deployment contract below is met.

> Earlier revisions claimed “95%”. That figure described **confidence under a narrow contract**,
> not internet-scale multi-tenant readiness. This file is the single source of truth going forward.

## Scorecard (evidence-based, 2026-07-20)

| Dimension | Score | Evidence |
|-----------|-------|----------|
| Correctness / reliability | **7.0 / 10** | Pool magic/`checked_out`, concurrency fixes; **no request idle timeout**; shutdown drain can wait forever without `drain_timeout_ms` |
| Security | **6.5 / 10** | CSRF, parameterized SQL, rate-limit defaults ignore spoofable headers, Cookie HttpOnly+SameSite; **AuthInterceptor is cookie-presence only**; default CORS `*`; TLS at reverse proxy |
| Observability | **6.5 / 10** | Logger, Metrics, `healthHandlerFor`, Prometheus exporter; core server does **not** auto-record metrics |
| Ops / deployability | **5.5 / 10** | CI + Docker exist; Docker must pin Zig (see `docker/Dockerfile`); version metadata historically drifted |
| Docs / AI tooling | **8.5 / 10** | `zf`, skills, dual data-layer (`DB` + `zent`), ai-edit-zones |
| Optional (PG/MySQL/zent/messaging) | **5.0 / 10** | SQLite strongest; PG/MySQL opt-in / not default CI; zent new (0.13.10); RobustMQ consume incomplete |
| **Overall** | **6.8 / 10** | Controlled deploy: usable. Public multi-instance + message consume: not ready |

## Deployment contract (required for ~7.5–8 / 10)

1. Pin Zig to the **exact** CI version (`0.17.0-dev.1422+e863bf3be` or whatever CI currently uses).
2. Terminate TLS at nginx/caddy; set proxy **read/write/idle timeouts**.
3. Enable `RateLimitHandler.trust_proxy_headers` **only** with `trusted_proxies` set to proxy peer(s).
4. Do **not** ship `CORSInterceptor` (`Allow-Origin: *`) on credentialed APIs — use `createCorsInterceptor(origin)`.
5. Do **not** treat `AuthInterceptor` as real auth — implement JWT/session yourself.
6. Prefer SQLite, or PG/MySQL only after live tests (`-Ddriver_pg` / `-Ddriver_mysql`).
7. Do not use `zfinal.experimental.*` without an ADR.
8. Wire CSRF (`createTokenInterceptor`) on state-changing routes; call `shutdown.registerHandlers()` before `app.start()`.
9. Handlers free via `ctx.allocator` (no per-request Arena abuse).

**Scale-out:** [`doc/scale_to_millions.md`](doc/scale_to_millions.md) · [`doc/progressive_architecture.md`](doc/progressive_architecture.md).

## Known residual gaps

| Gap | Severity | Mitigation |
|-----|----------|------------|
| Zig **0.17-dev** toolchain drift | P0 | Pin + CI; rebuild on every Zig bump |
| No per-request idle/read timeout in core server | P0 | Set at reverse proxy; framework `drain_timeout_ms` caps shutdown wait |
| Keep-alive forced `Connection: close` | P1 | Zig `http.Server` workaround (`src/core/server.zig`) |
| PG/MySQL not on default CI matrix | P1 | Opt-in live env vars |
| Version / tag / README historically drifted | P1 | Keep `build.zig.zon` + README badge + CHANGELOG aligned |
| Memory Session; weak AuthInterceptor | P1 | External session store + real auth |
| zent as “primary” is early | P2 | Demo + AI codegen; bake before SLA path |
| RobustMQ consumer incomplete; MQTT no TLS | P2 | Prefer publish / NATS until consume lands |
| Redis connect has no app-level deadline | P3 | OS / Io timeouts |

## Verification commands

```bash
zig build
zig build test          # expect ~190+ passed; skips for live NATS/RobustMQ/TLS paths
zig build test-zf
zig build -Doptimize=ReleaseSafe
zig fmt --check src/ tools/ examples/ benchmark/ build.zig
zf check
```

## Changelog of this reassessment (2026-07-20)

- Honest **6.8/10** scorecard replacing marketing 95%
- Production example: CSRF + rate limit + shutdown + restricted CORS
- `ServerConfig.drain_timeout_ms` hard-caps graceful drain
- `createCorsInterceptor(origin)` for non-wildcard CORS
- Docker Zig pin notes + CI-aligned version
- Version metadata aligned to **0.13.10**
