# Performance Benchmarking

This directory contains tools to benchmark the `zfinal` framework.

## Prerequisites

- **Server**: Ensure the `zfinal` demo server is running on port 8080.
  ```bash
  zig build run-blog
  ```

## Option 1: Apache Bench (ab)

If you have `ab` installed (usually comes with macOS/Apache), you can use the shell script:

```bash
./benchmark/run_ab.sh
```

This script runs three scenarios:
1. **GET /**: Simple text response.
2. **GET /api/posts**: JSON list response.
3. **POST /api/users**: JSON body parsing and response.

## Option 2: Zig Benchmark Tool (zbench)

A custom benchmark tool written in Zig is available. It uses `std.http.Client` to stress test the server.

### Usage

```bash
# Run with default settings (URL: http://127.0.0.1:8080/, Requests: 10000, Concurrency: 50)
zig build run-bench

# Run with custom arguments
zig build run-bench -- http://127.0.0.1:8080/api/posts 20000 100
```

Arguments:
1. **URL**: Target URL (default: `http://127.0.0.1:8080/`)
2. **Requests**: Total number of requests (default: `10000`)
3. **Concurrency**: Number of concurrent threads (default: `50`)

## Option 3: sockread / HttpClient micro-bench

Quantifies the shared-Threaded-Io hang fix and HttpClient isolation tax:

```bash
zig build run-sockread-bench
```

Reports:
1. **threaded_lifecycle** — cost of `Io.Threaded` init/deinit (once per `HttpClient.init`).
2. **warm_read_sockread** vs **warm_read_io_net_read** — data already in kernel buffer.
3. **local_http_reused_io** — loopback GET with long-lived dedicated Io (amortized).

## Expected Performance

On a modern machine (e.g., M1/M2/M3 Mac), you should expect:
- **RPS**: 20,000 - 50,000+ req/s (depending on endpoint complexity)
- **Latency**: < 1ms average

## Notes

- Ensure you build in `ReleaseSafe` or `ReleaseFast` mode for accurate performance testing of the framework itself (though `run-blog` defaults to Debug, you might want to build it with `-Doptimize=ReleaseSafe`).
  ```bash
  zig build run-blog -Doptimize=ReleaseSafe
  ```
- ZFinal defaults to `force_connection_close=true` (see [`doc/reverse_proxy.md`](../doc/reverse_proxy.md)). For apples-to-apples baselines, keep that default; optional nginx in front absorbs client keep-alive.

## Formal baseline

Record numbers in [`BASELINE.md`](BASELINE.md) whenever you change HTTP stack, allocator, or router hot paths.

| Setting | Value |
|---------|--------|
| Optimize | `ReleaseSafe` (or `ReleaseFast` for peak RPS — note in BASELINE.md) |
| `force_connection_close` | `true` (default) |
| Server | `zig build run-blog -Doptimize=ReleaseSafe` on `:8080` |
| Tool | `./benchmark/run_ab.sh` or `zig build run-bench -- <url> <n> <c>` |
| Optional | nginx upstream per `examples/production/deploy/nginx.conf` |

**How to record:** copy `BASELINE.md`, fill date/machine/git SHA/commands, paste `ab` or `run-bench` RPS + p50/p99. Re-run after regressions; do not compare Debug vs ReleaseSafe numbers.
