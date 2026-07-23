# ZFinal Framework — Production Readiness Audit

**Date:** 2026-07-23 (CHANGELOG / package **0.20.3**)  
**Zig:** `0.17.0-dev.1422+e863bf3be` (pinned in CI; `minimum_zig_version` in `build.zig.zon`)  
**Status:** **Production-ready under the deployment contract below.**  
**Headline score (contractual):** **9.8 / 10**  
**Absolute score (Zig 0.17-dev + keep-alive default-off):** **~9.2 / 10**

> **9.8** assumes pinned Zig, reverse-proxy TLS/timeouts, JWT + CSRF + rate-limit
> + security headers + request ID as in `examples/production`, CI live PG/MySQL,
> and `zf check --prod` (0 fail on the reference example).
> Absolute ceiling stays under 10 until Zig 0.17 stable and keep-alive is default-safe
> (ziglang/zig#25017 — still asserts on pinned 0.17-dev; mitigated via force-close + drain + proxy).

## Scorecard (evidence-based, 2026-07-23)

| Dimension | Score | Evidence |
|-----------|-------|----------|
| Correctness / reliability | **9.8 / 10** | **`read_timeout_ms` via `operateTimeout(net_read)`** + idle watchdog; **`write_timeout_ms` wall-clock**; body drain; keep-alive opt-in; **#25017 regression tests** |
| Security | **9.8 / 10** | JWT HS256 + **RS256 verify** + nbf/iss/aud + rotation; CORS allow-list; security headers + request ID; CSRF/rate-limit; `zf check --prod --root` |
| Observability | **9.9 / 10** | Auto Metrics + latency histogram + route-class counters + **route-class latency sum/count**; `/metrics`; probe health |
| Ops / deployability | **9.8 / 10** | CI matrix + drivers + live PG/MySQL + production binary + **`zf check --prod`** + [`doc/reverse_proxy.md`](doc/reverse_proxy.md) |
| Docs / AI tooling | **9.8 / 10** | version SSoT; zone-preserving regen; ports-l2; reverse-proxy KA guide |
| Optional (PG/MySQL/zent/messaging) | **9.4 / 10** | Live CI; Redis; RobustMQ JoinGroup + **Metadata** + range rebalance + OffsetFetch/LeaveGroup; MQTT TLS still proxy |
| **Overall (contractual)** | **9.8 / 10** | Internet-facing BFF behind proxy: ready |
| Absolute (toolchain) | **~9.2 / 10** | Zig-dev + keep-alive still default-forced |

## Deployment contract (required for 9.8 / 10)

1. Pin Zig to the **exact** CI version (`0.17.0-dev.1422+e863bf3be`).
2. Terminate TLS at nginx/caddy; set proxy timeouts. **Client keep-alive at the proxy; keep `force_connection_close=true` on ZFinal** — [`doc/reverse_proxy.md`](doc/reverse_proxy.md), [`examples/production/deploy/`](examples/production/deploy/).
3. Prefer `createRateLimitInterceptor` with `trusted_proxies` only behind known peers.
4. Prefer `createCorsAllowlistInterceptor` — never ship `CORSInterceptor` (`*`) on credentialed APIs.
5. Use **`createJwtAuthInterceptorWithOptions`** / `jwtVerifyWithOptions` — [`doc/session.md`](doc/session.md).
6. Add **`createSecurityHeadersInterceptor(true)`** behind TLS termination; set `ENABLE_HSTS=1` when appropriate.
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
| Keep-alive unsafe by default | P1 | force-close + proxy KA + drain helper + **CI regression**; wait #25017 to flip default |
| MQTT native TLS | P2 | Proxy / `TlsNotImplemented` |
| High-cardinality route labels | P3 | Coarse health/metrics/api/other only |
| JWT RS256 sign | P3 | Verify done; sign remains HS256 |

## Gaps closed (recent)

| Gap | Fix |
|-----|-----|
| Zone-preserving regen | `zone_merge` in `safeWrite` |
| `zf check --prod --root` | Portable contract scan |
| JWT RS256 verify | `jwtVerifyRs256` |
| Kafka range rebalance | classic range + SyncGroup assignment |
| Kafka Metadata partition count | Metadata v1; `partition_count=0` auto |
| Reverse-proxy KA practice | `doc/reverse_proxy.md` + `examples/production/deploy/` |
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
