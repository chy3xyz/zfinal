# Performance notes — lessons from [Lighting](https://github.com/jiacai2050/lighting)

Lighting is a Zig 0.17 HTTP framework that reaches hundreds of thousands of
QPS on keep-alive microbenchmarks (`/ping`) with ~7 MB RSS. ZFinal is a
fuller application framework (ORM, CSRF, metrics, WS, …) and deliberately
defaults to **`force_connection_close=true`** until Zig `std.http.Server`
keep-alive is safe (ziglang/zig#25017). This doc records what we **ported**
and what we **intentionally did not**.

## What Lighting does well

| Technique | Effect |
|-----------|--------|
| True HTTP/1.1 keep-alive + pipelining | Avoids TCP handshake per request |
| Connection-scoped arena (`retain_with_limit`) | O(1) free, low fragmentation |
| Zero-copy header parse (slices into conn buf) | No per-header `dupe` |
| 4 KiB stack `ResponseWriter` + `writev` | Zero-heap small responses |
| Absolute header / idle deadlines | Slowloris defense without relative SO_RCVTIMEO |
| Custom HTTP stack (not `std.http.Server`) | Full control of KA / drain |

## What ZFinal adopted (v0.28.8)

1. **Lazy request-header cache** — `getHeader` uses `iterateHeaders` in P1;
   `cacheHeaders()` only runs immediately before body consumption.
2. **Gzip threshold 4 KiB** — `ServerConfig.compress_min_bytes` (was effectively 256).
3. **Stack response headers** — `Context.respondBody` uses `[16]Header` when
   there are no `Set-Cookie`s and ≤16 total headers.
4. **Zero-alloc interceptor chain** — `Router.execute` runs global + route
   interceptors in place (no per-request `InterceptorChain` merge).
5. **8 KiB connection buffers** — matches Lighting’s default read size.

## What ZFinal adopted (v0.28.10 KA-prep + alloc)

6. **Bounded unread-body drain** — `max_drain_body_bytes` (256 KiB); over limit
   → `keep_alive=false` (`keepalive_safety.DrainResult.too_large`).
7. **Absolute header / idle / body deadlines** — `read_header_timeout_ms` (5s),
   `idle_timeout_ms` (120s), absolute `read_timeout_ms` via `TimedIoReader`.
8. **Empty Context HashMaps** — no `ensureTotalCapacity` on init.
9. **`smp_allocator`** in production/blog/blog-single for non-Debug builds.

## Biggest remaining gap (do not flip casually)

```zig
ServerConfig.force_connection_close = true; // production default
```

Lighting’s QPS assumes keep-alive. ZFinal’s blog baseline (~22–25k RPS) is
dominated by connection close. To measure the ceiling:

```bash
# Only after soak tests + body-drain coverage — see doc/reverse_proxy.md
zig build run-blog -Doptimize=ReleaseFast
# ServerConfig / app.setConfig(.{ .force_connection_close = false, ... })
```

Prefer reverse-proxy keep-alive in production until #25017 is fixed.

## What ZFinal adopted (v0.28.11 close-mode hot path)

10. **Skip `registerConn` under `force_connection_close`** — short HTTP no longer
    takes the global `conns_mutex` twice per request; WebSocket still registers
    lazily so SIGTERM can `interruptConnections`. Keep-alive mode still tracks
    every connection from accept.
11. **Example request logging opt-in in Release\*** — blog / blog-single
    `LoggingInterceptor` prints only when `ZF_REQUEST_LOG=1` (Debug stays on).
    Avoids `std.debug.print` global lock tanking bench RPS.

## Remaining portable wins (after v0.28.11)

| Rank | Technique | Notes |
|------|-----------|-------|
| **E+** | Fully lazy optional HashMaps | null until first put; avoid Arena restore |
| **F** | Contiguous header buf → 1–2 iovec | Blocked on `std.http.respond` |
| **G** | `Expect: 100-continue` | Protocol correctness for large POST |

### Still gated on zig#25017 + soak

- `force_connection_close = false`（Lighting QPS 主杠杆）
- Pipelining leftover `copyForwards`
- Connection-scoped `ArenaAllocator.reset(.retain_with_limit = 64KiB)`

### Suggested next

1. Write-path iovec probe / KA soak harness (no default flip).
2. Optional fully-lazy Context maps if profiling still shows HashMap init cost.
3. Re-bench blog ReleaseSafe with loadavg in single digits; append `BASELINE.md`.

## What we did **not** copy

- Full custom HTTP parser / `ResponseWriter` rewrite
- zio / core-pinning / heterogeneous-CPU bench harness
- Replacing the ServeMux decision tree wholesale
- Unconditional per-request Arena for all containers (historical segfault)
- Fragmented zero-copy iovec floods (Lighting themselves abandoned this)

Those are high risk / low ROI relative to allocation + KA policy work above.

## Verify

```bash
zig build test
zig build run-blog -Doptimize=ReleaseSafe
./benchmark/run_ab.sh   # or zig build run-bench
```
