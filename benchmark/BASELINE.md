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
```

## Results

| Scenario | RPS | Mean ms | p99 ms | Notes |
|----------|-----|---------|--------|-------|
| GET / | | | | |
| GET /api/posts | | | | |
| POST /api/users | | | | |

## Observations

- (optional) nginx vs direct, concurrency sweep, etc.
