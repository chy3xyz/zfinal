# ZFinal Framework — Production Readiness Audit

**Date:** 2026-07-20 (CHANGELOG / package **0.13.10**)  
**Zig:** `0.17.0-dev.1422+e863bf3be` (pinned in CI; `minimum_zig_version` in `build.zig.zon`)  
**Status:** **Production-ready under the deployment contract below.**  
**Headline score (contractual):** **9.5 / 10**  
**Absolute score (Zig 0.17-dev + keep-alive workaround):** **~8.7 / 10**

> Score meaning: **9.5** is for teams that pin Zig, terminate TLS at a reverse proxy,
> wire JWT + CSRF + rate-limit as shown in `examples/production`, and keep optional
> drivers (PG/MySQL/zent messaging) on the CI compile path. Absolute ceiling remains
> below 10 until Zig ships a stable 0.17 release and HTTP keep-alive is restored.

## Scorecard (evidence-based, 2026-07-20)

| Dimension | Score | Evidence |
|-----------|-------|----------|
| Correctness / reliability | **9.5 / 10** | Pool/`checked_out`; **`request_timeout_ms` idle watchdog**; **`drain_timeout_ms`**; auto Metrics in dispatch |
| Security | **9.4 / 10** | CSRF; parameterized SQL; rate-limit defaults ignore spoofable headers; **`createJwtAuthInterceptor` (HS256)**; **`createCorsInterceptor`**; Cookie HttpOnly+SameSite |
| Observability | **9.5 / 10** | Logger; Metrics auto-record; `healthHandlerFor` + **`healthHandlerWithChecks` probes**; Prometheus exporter |
| Ops / deployability | **9.3 / 10** | CI matrix (ubuntu/macOS) + **PG/MySQL/zent compile job** + production binary assert; Docker Zig pin; version aligned |
| Docs / AI tooling | **9.2 / 10** | `zf`, skills, dual data-layer (`DB` + `zent`), ai-edit-zones |
| Optional (PG/MySQL/zent/messaging) | **8.5 / 10** | Drivers compile in CI; live DB still env-gated; zent early but AI-first; RobustMQ consume incomplete |
| **Overall (contractual)** | **9.5 / 10** | Controlled + internet-facing BFF behind proxy: ready |
| Absolute (toolchain) | **~8.7 / 10** | Zig-dev drift + forced `Connection: close` residual |

## Deployment contract (required for 9.5 / 10)

1. Pin Zig to the **exact** CI version (`0.17.0-dev.1422+e863bf3be`).
2. Terminate TLS at nginx/caddy; set proxy **read/write/idle timeouts** (complement `request_timeout_ms`).
3. Enable `RateLimitHandler.trust_proxy_headers` **only** with `trusted_proxies` set to proxy peer(s). Prefer `createRateLimitInterceptor`.
4. Do **not** ship `CORSInterceptor` (`Allow-Origin: *`) on credentialed APIs — use `createCorsInterceptor(origin)`.
5. Use **`createJwtAuthInterceptor(secret)`** (or equivalent session verify). Do **not** use demo `AuthInterceptor`.
6. Prefer SQLite, or PG/MySQL after live tests (`-Ddriver_pg` / `-Ddriver_mysql`). CI compiles both.
7. Do not use `zfinal.experimental.*` without an ADR.
8. Wire CSRF (`createTokenInterceptor`) on state-changing routes; call `shutdown.registerHandlers()` before `app.start()`.
9. Call `app.setMetrics(&metrics)` so dispatch records status classes; expose `/health` via `healthHandlerWithChecks`.
10. Handlers free via `ctx.allocator` (no per-request Arena abuse).
11. Set `JWT_SECRET` / `CORS_ORIGIN` from the environment in production (see `examples/production`).

**Reference app:** [`examples/production/main.zig`](examples/production/main.zig)  
**Scale-out:** [`doc/scale_to_millions.md`](doc/scale_to_millions.md) · [`doc/progressive_architecture.md`](doc/progressive_architecture.md).

## Known residual gaps

| Gap | Severity | Mitigation |
|-----|----------|------------|
| Zig **0.17-dev** toolchain drift | P1 | Pin + CI; rebuild on every Zig bump |
| Keep-alive forced `Connection: close` | P1 | Zig `http.Server` workaround (`src/core/server.zig`); OK behind short-lived proxy connections |
| PG/MySQL live tests not default | P2 | Compile-gated in CI; live via env |
| Memory Session store | P2 | External session / JWT-stateless |
| zent “primary” still early | P2 | Demo + AI codegen; bake before hard SLA |
| RobustMQ consumer incomplete; MQTT no TLS | P2 | Prefer publish / NATS until consume lands |
| Redis connect has no app-level deadline | P3 | OS / Io timeouts |

## Gaps closed in this push (→ 9.5)

| Gap (was) | Fix |
|-----------|-----|
| No request idle timeout | `ServerConfig.request_timeout_ms` + per-conn idle watchdog |
| Metrics not auto-recorded | `Server.metrics` / `ZFinal.setMetrics` → `recordConnection`/`recordRequest` |
| Weak AuthInterceptor | `src/auth/jwt.zig` + `createJwtAuthInterceptor` |
| Manual rate-limit only | `createRateLimitInterceptor` |
| Health without probes | `healthHandlerWithChecks` / `HealthCheck` |
| Drivers off CI | `drivers-compile` job (`-Ddriver_pg` / `-Ddriver_mysql` / zent) |
| Production path unasserted | `production-example` job asserts `zig-out/bin/production` |

## Verification commands

```bash
zig build
zig build test          # expect ~190+ passed; skips for live NATS/RobustMQ/TLS paths
zig build test-zf
zig build -Doptimize=ReleaseSafe
zig build -Ddriver_pg=true -Ddriver_mysql=true -Denable-zent=true
zig fmt --check src/ tools/ examples/ benchmark/ build.zig
zf check
```

## Changelog of this reassessment (2026-07-20)

- Honest **6.8 → 9.5 (contractual)** after P0/P1 hardening
- Request idle timeout + drain deadline
- Auto Metrics + probe health
- Real HS256 JWT auth + rate-limit interceptor
- Restricted CORS; production example updated
- CI: driver compile matrix + production binary gate
- Version metadata aligned to **0.13.10**
