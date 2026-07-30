# ZFinal Framework — Production Readiness Audit

**Date:** 2026-07-31 (CHANGELOG / package **0.20.9**)  
**Zig:** `0.17.0-dev.1422+e863bf3be` (pinned in CI; `minimum_zig_version` in `build.zig.zon`)  
**Status:** **Production-ready under the deployment contract below.**  
**Headline score (contractual):** **9.8 / 10**  
**Absolute score (Zig 0.17-dev + keep-alive default-off):** **~9.2 / 10**

> **9.8** assumes pinned Zig, reverse-proxy TLS/timeouts, JWT + CSRF + rate-limit
> + security headers + request ID as in `examples/production`, CI live PG/MySQL,
> and `zf check --prod` (0 fail on the reference example).
> Absolute ceiling stays under 10 until Zig 0.17 stable and keep-alive is default-safe
> (ziglang/zig#25017 — still asserts on pinned 0.17-dev; mitigated via force-close + drain + proxy).
>
> **2026-07-31 refresh:** HttpError / Extension / `oneshot.captureWith` / interceptor
> `userdata` (no static secrets) landed; keep-alive residual unchanged — flip checklist still
> [`doc/reverse_proxy.md`](doc/reverse_proxy.md) §9.

## Scorecard (evidence-based, 2026-07-23)

| Dimension | Score | Evidence |
|-----------|-------|----------|
| Correctness / reliability | **9.8 / 10** | **`read_timeout_ms` via `operateTimeout(net_read)`** + idle watchdog; **`write_timeout_ms` wall-clock**; body drain; keep-alive opt-in; **#25017 regression tests** |
| Security | **9.9 / 10** | JWT HS256 + **RS256 sign/verify** + nbf/iss/aud + rotation; CORS; security headers + request ID; CSRF/rate-limit; `zf check --prod --root` |
| Observability | **9.9 / 10** | Auto Metrics + latency histogram + **6 route classes** (health/metrics/api/admin/static/other) + `routeTemplate`; `/metrics` |
| Ops / deployability | **9.8 / 10** | CI + drivers + live PG/MySQL + production + **`zf check --prod`** + [`doc/reverse_proxy.md`](doc/reverse_proxy.md) + [`benchmark/BASELINE.md`](benchmark/BASELINE.md) |
| Docs / AI tooling | **9.8 / 10** | zone merge; ports-l2/**ports-l3**; reverse-proxy KA; deeper `zf openapi` (bearerAuth/body/responses) |
| Optional (PG/MySQL/zent/messaging) | **9.6 / 10** | RobustMQ Metadata + range/sticky + Offset*; **MQTT native TLS**; Redis; live CI |
| **Overall (contractual)** | **9.8 / 10** | Internet-facing BFF behind proxy: ready |
| Absolute (toolchain) | **~9.2 / 10** | Zig-dev + keep-alive still default-forced |

## Deployment contract (required for 9.8 / 10)

1. Pin Zig to the **exact** CI version (`0.17.0-dev.1422+e863bf3be`).
2. Terminate TLS at nginx/caddy; set proxy timeouts. **Client keep-alive at the proxy; keep `force_connection_close=true` on ZFinal** — [`doc/reverse_proxy.md`](doc/reverse_proxy.md), [`examples/production/deploy/`](examples/production/deploy/).
3. Prefer `createRateLimitInterceptor` with `trusted_proxies` only behind known peers.
4. Prefer `createCorsAllowlistInterceptor` — never ship `CORSInterceptor` (`*`) on credentialed APIs.
5. Use **`createJwtAuthInterceptorWithOptions`** / `jwtVerifyWithOptions` — [`doc/session.md`](doc/session.md).
6. Add **`createSecurityHeadersInterceptor`** with caller-owned `SecurityHeadersConfig{ .include_hsts = true }` behind TLS; set `ENABLE_HSTS=1` when appropriate.
7. Add **`createRequestIdInterceptor()`** globally for trace correlation.
8. Prefer SQLite or PG/MySQL (CI `drivers-live` exercises both).
9. Do not use `zfinal.experimental.*` without an ADR.
10. Wire CSRF; call `shutdown.registerHandlers()` before `app.start()`.
11. Call `app.setMetrics(&metrics)`; expose `/health` + `/metrics`.
12. Keep `force_connection_close=true` until zig#25017 + soak tests (verified still asserts on `0.17.0-dev.1422`).
13. Set `JWT_SECRET` / `JWT_SECRET_PREVIOUS` / `JWT_ISS` / `JWT_AUD` / `CORS_ORIGIN` from the environment.
14. Run **`zf check --prod`** before release.
15. Handlers free via `ctx.allocator`.

**Reference:** [`examples/production/main.zig`](examples/production/main.zig)

## Known residual gaps

| Gap | Severity | Status |
|-----|----------|--------|
| Zig **0.17-dev** drift | P1 | Pin + CI |
| Keep-alive unsafe by default | P1 | force-close + proxy KA + drain + CI regression; flip checklist in [`doc/reverse_proxy.md`](doc/reverse_proxy.md) §9; wait #25017 |
| OpenAPI per-entity DTO fields | P2 | **Closed 2026-07-31** — ORM `pub const Name = struct` → `Name`/`NameInput` schemas |

## Gaps closed (2026-07-31)

| Gap | Fix |
|-----|-----|
| Interceptor static `var` secrets | `userdata` + caller-owned `*const Cfg` (no `heapCfg`); `zf check` WARNs temporary `&.{` cfg |
| `oneshot.capture` no headers | `captureWith` + `Context.mock_headers` / `mock_body` |
| Extension 16 slots | capacity 32 + clearer full log |
| Trace attr strings | `extension.TraceMeta` |
| Cache interceptor stub | GET hit-only (+ capture store); TCP after-store documented + `--prod` WARN |
| Hand-rolled error envelopes | `zf check` WARN scan |

## Gaps closed (recent)

| Gap | Fix |
|-----|-----|
| Zone-preserving regen | `zone_merge` in `safeWrite` |
| `zf check --prod --root` | Portable contract scan |
| JWT RS256 verify + sign | `jwtVerifyRs256` / `jwtSignRs256` |
| Kafka range + sticky + Metadata | classic assignors + Metadata v1 |
| MQTT native TLS | `std.crypto.tls.Client` + `tls_insecure` |
| Metrics 6 route classes | health/metrics/api/admin/static/other + `routeTemplate` |
| OpenAPI deepen | bearerAuth + JSON body + 400/401/404 |
| L3 ports example | `examples/ports-l3` Outbox + tenant |
| Reverse-proxy KA + flip checklist | `doc/reverse_proxy.md` §9 |
| Benchmark baseline template | `benchmark/BASELINE.md` |
| #25017 regression coverage | `src/core/keepalive_safety.zig` |

## Gaps closed (0.20.x)

| Gap | Fix |
|-----|-----|
| `write_timeout_ms` ignored after Zig dropped `net_write` | Wall-clock deadline from first `TimedWriter.drain` per response |
| Version / manifest drift (0.13.11 leftovers) | `src/version.zig` + build options; manifests use `semver` |
| No per-route latency | `recordRouteLatencyMs` + Prometheus `zfinal_request_duration_by_route_ms` |
| JWT options not wired in example | `createJwtAuthInterceptorWithOptions` + env `JWT_ISS`/`JWT_AUD`/`JWT_SECRET_PREVIOUS` |
| Missing security baseline | `createSecurityHeadersInterceptor` + `createRequestIdInterceptor` |
| Contract scan too noisy | `zf check --prod` scopes to `examples/production` + required wiring asserts |

## Verification commands

```bash
zig build
zig build test
zig build test-zf
zig build -Doptimize=ReleaseSafe
zig build test -Ddriver_pg=true -Ddriver_mysql=true
zig build install && zf check --prod
zig fmt --check src/ tools/ examples/ benchmark/ build.zig
```
