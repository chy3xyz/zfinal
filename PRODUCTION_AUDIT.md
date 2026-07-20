# ZFinal Framework — Production Readiness Audit

**Date:** 2026-07-20 (CHANGELOG / package **0.13.10**)  
**Zig:** `0.17.0-dev.1422+e863bf3be` (pinned in CI; `minimum_zig_version` in `build.zig.zon`)  
**Status:** **Production-ready under the deployment contract below.**  
**Headline score (contractual):** **9.7 / 10**  
**Absolute score (Zig 0.17-dev + keep-alive default-off):** **~9.0 / 10**

> **9.7** assumes pinned Zig, reverse-proxy TLS/timeouts, JWT + CSRF + rate-limit
> as in `examples/production`, CI live PG/MySQL, and `zf check --prod`.
> Absolute ceiling stays under 10 until Zig 0.17 stable and keep-alive is default-safe
> (ziglang/zig#25017).

## Scorecard (evidence-based, 2026-07-20)

| Dimension | Score | Evidence |
|-----------|-------|----------|
| Correctness / reliability | **9.7 / 10** | **`read_timeout_ms` via `operateTimeout(net_read)`** + idle watchdog; drain; body drain all renders; keep-alive opt-in |
| Security | **9.6 / 10** | JWT nbf/iss/aud + alg=none + rotation; CORS allow-list; CSRF/rate-limit audit; `zf check --prod` |
| Observability | **9.8 / 10** | Auto Metrics + latency histogram + **route-class counters**; `/metrics`; probe health |
| Ops / deployability | **9.6 / 10** | CI matrix + drivers compile + **live PG/MySQL** + production binary + **`zf check --prod`** |
| Docs / AI tooling | **9.4 / 10** | session.md, zent SLA, robustmq decode notes, dual AI path |
| Optional (PG/MySQL/zent/messaging) | **9.0 / 10** | Live CI; Redis deadlines; **RobustMQ RecordBatch decode**; MQTT TLS sentinel; group consume still open |
| **Overall (contractual)** | **9.7 / 10** | Internet-facing BFF behind proxy: ready |
| Absolute (toolchain) | **~9.0 / 10** | Zig-dev + keep-alive still default-forced |

## Deployment contract (required for 9.7 / 10)

1. Pin Zig to the **exact** CI version (`0.17.0-dev.1422+e863bf3be`).
2. Terminate TLS at nginx/caddy; set proxy timeouts (complement `read_timeout_ms` / `request_timeout_ms`).
3. Prefer `createRateLimitInterceptor` with `trusted_proxies` only behind known peers.
4. Prefer `createCorsAllowlistInterceptor` — never ship `CORSInterceptor` (`*`) on credentialed APIs.
5. Use **`createJwtAuthInterceptor`** / `jwtVerifyWithOptions` — [`doc/session.md`](doc/session.md).
6. Prefer SQLite or PG/MySQL (CI `drivers-live` exercises both).
7. Do not use `zfinal.experimental.*` without an ADR.
8. Wire CSRF; call `shutdown.registerHandlers()` before `app.start()`.
9. Call `app.setMetrics(&metrics)`; expose `/health` + `/metrics`.
10. Keep `force_connection_close=true` until zig#25017 + soak tests.
11. Set `JWT_SECRET` / `CORS_ORIGIN` from the environment.
12. Run **`zf check --prod`** before release.
13. Handlers free via `ctx.allocator`.

**Reference:** [`examples/production/main.zig`](examples/production/main.zig)

## Known residual gaps

| Gap | Severity | Status |
|-----|----------|--------|
| Zig **0.17-dev** drift | P1 | Pin + CI |
| Keep-alive unsafe by default | P1 | `force_connection_close=true`; wait #25017 |
| Stream **write** `operateTimeout` | P2 | Idle watchdog covers write stalls |
| RobustMQ consumer group | P2 | Values decode done; JoinGroup etc. open |
| MQTT native TLS | P2 | Proxy / `TlsNotImplemented` |
| JWT RS256 | P3 | HS256 + rotation |
| High-cardinality route labels | P3 | Coarse health/metrics/api/other only |

## Gaps closed toward 9.7

| Gap | Fix |
|-----|-----|
| No Io read deadline | `TimedReader` + `ServerConfig.read_timeout_ms` |
| Global-only metrics | `recordRoute` + Prometheus `zfinal_requests_by_route_total` |
| Fetch decode stub | `parseFetchValues` / `parseRecordBatchValues` (+ test) |
| Contract unenforced | `zf check --prod` |
| Prior 9.5 hardening | JWT/CORS/audit/Redis/CI live/session docs (previous push) |

## Verification commands

```bash
zig build
zig build test
zig build test-zf
zig build -Doptimize=ReleaseSafe
zig build test -Ddriver_pg=true -Ddriver_mysql=true
zf check --prod
zig fmt --check src/ tools/ examples/ benchmark/ build.zig
```
