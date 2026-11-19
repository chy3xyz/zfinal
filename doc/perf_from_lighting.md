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

## What we did **not** copy

- Full custom HTTP parser / `ResponseWriter` rewrite
- zio / core-pinning / heterogeneous-CPU bench harness
- Replacing the ServeMux decision tree wholesale

Those are high risk / low ROI relative to allocation + KA policy work above.

## Verify

```bash
zig build test
zig build run-blog -Doptimize=ReleaseSafe
./benchmark/run_ab.sh   # or zig build run-bench
```
