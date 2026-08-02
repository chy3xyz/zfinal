# ZFinal benchmark baseline template

Copy this file (or append a dated section) when recording official numbers.

## Run metadata

| Field | Value |
|-------|--------|
| Date | YYYY-MM-DD |
| Machine | e.g. Apple M3 Pro, 36 GB |
| OS | e.g. macOS 15.x |
| Zig version | `zig version` output |
| Git SHA | `git rev-parse --short HEAD` |
| Optimize | ReleaseSafe / ReleaseFast |
| `force_connection_close` | true / false |
| Reverse proxy | none / nginx (config path) |

## Commands

```bash
# Terminal 1 — server
zig build run-blog -Doptimize=ReleaseSafe

# Terminal 2 — benchmark
./benchmark/run_ab.sh
# or:
zig build run-bench -- http://127.0.0.1:8080/api/posts 10000 50

# sockread / HttpClient isolation micro-bench (no external server)
zig build run-sockread-bench
```

### Sample: sockread micro-bench (local, illustrative)

| Metric | ns/op (approx) | Notes |
|--------|----------------|-------|
| threaded_lifecycle | ~1.8µs | Once per `HttpClient.init` (not per request) |
| warm_read_sockread | ~1.0µs | DONTWAIT/read-first; closer to Io warm path |
| warm_read_io_net_read | ~0.8µs | Io path when it works |
| local_http_reused_io | ~171µs | loopback GET; Client pool (bench server is close) |

Re-run and paste your machine's numbers when changing sockread / HttpClient.

## Results

| Scenario | RPS | Mean ms | p99 ms | Notes |
|----------|-----|---------|--------|-------|
| GET / | | | | |
| GET /api/posts | | | | |
| POST /api/users | | | | |

## Observations

- (optional) nginx vs direct, concurrency sweep, etc.
