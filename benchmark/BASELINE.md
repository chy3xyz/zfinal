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

---

## 2026-09-27 — v0.28.0 full evaluation (Apple M1 Pro 10-core, macOS)

| Field | Value |
|-------|--------|
| Machine | Apple M1 Pro, 10 cores |
| OS | macOS (Darwin 25) |
| Zig version | `0.17.0-dev.2151+2ec5523d5` |
| Git SHA | `0189ee4` (v0.28.0) |
| Optimize | HTTP: ReleaseSafe · micro: ReleaseFast |
| `force_connection_close` | true (documented production posture) |
| Reverse proxy | none |
| Server | blog-single (SQLite) on :8080, threads=10 |
| Load tool | `zbench` (std.http.Client workers) + `ab` |

### HTTP (blog-single)

| Scenario | RPS | avg ms | p50/p95/p99 (ab) | failed |
|----------|-----|--------|-------------------|--------|
| GET / c=64 n=20k | 21,898 | 2.91 | — | 2/20k (client) |
| GET /api/posts c=1 | 6,850 | 0.15 | — | 0 |
| GET /api/posts c=16 | 21,785 | 0.73 | — | 27/20k (client) |
| GET /api/posts c=64 | 22,867 | 2.79 | 2 / 3 / 6 | 0 |
| GET /api/posts c=64 ab -k | 25,105 | 2.55 (0.040 server) | 2 / 3 / 6 | 0 |
| GET /api/posts c=128 | 19,008 | 6.63 | — | 3/30k |
| GET /api/posts c=256 | 20,077 | 11.93 | — | 0 |
| POST /api/users c=32 n=3k (write+hash) | 24,860 | 1.29 | — | 0 |

Server-side per-request cost ≈ 40 µs at saturation. Throughput saturates
around c=16–64 (~22–25k RPS); beyond that latency grows (queueing) while
RPS stays ~20k — the per-connection close cost dominates, matching the
reverse-proxy keep-alive posture in doc/reverse_proxy.md.

### DB result decoding (SQLite, 100k rows, ReleaseFast)

| Path | rows/s | ns/row | speedup |
|------|--------|--------|---------|
| legacy getText + parseInt | 60,528 | 16,521 | 1x |
| typed Row.getInt (error union) | 271,984 | ~3,677 | 4.5x |
| direct intAt cells | 335,506 | ~2,980 | 5.5x |

### ADR-017 declarative layer (in-memory SQLite)

| Item | ns/op |
|------|-------|
| Model.paginate baseline | 16,080 |
| Query.paginate (builder) | 15,800 (free vs baseline) |
| bindStruct (5 fields, comptime) | 7 |
| bindJsonInto (5-field JSON) | 293 |
| toView (borrow copy) | 0 (comptime-elided) |

### sockread / HttpClient micro (ReleaseFast)

| Item | ns/op |
|------|-------|
| threaded_lifecycle (once per client) | 1,517 |
| warm_read_sockread | 605 |
| warm_read_io_net_read | 673 |

### Build (DX)

| Scenario | time |
|----------|------|
| Cold full ReleaseSafe (framework + 25 example exes) | ~88 s wall (6m56 CPU) |
| Framework-core change (server.zig) | ~84 s (most binaries re-link) |
| App-only change (own project, 1 binary) | ~2–5 s observed |

### Observations

- HTTP saturates ~22–25k RPS with per-request close; latency p99 = 6 ms @ c=64.
- SQLite write+password-hash path holds 24.9k RPS — WAL + busy_timeout hold up.
- sporadic zbench "Failed" (≤27/20k) are client-side reconnect races against
  force-close; ab shows 0 failed — tooling artifact, not server errors.
- Framework-core edits rebuild most of the 25 example binaries (~84 s);
  application projects building a single binary are unaffected.
