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

## Expected Performance

On a modern machine (e.g., M1/M2/M3 Mac), you should expect:
- **RPS**: 20,000 - 50,000+ req/s (depending on endpoint complexity)
- **Latency**: < 1ms average

## Notes

- Ensure you build in `ReleaseFast` mode for accurate performance testing of the framework itself (though `run-blog` defaults to Debug, you might want to build it with `-Doptimize=ReleaseFast`).
  ```bash
  zig build run-blog -Doptimize=ReleaseFast
  ```
