<div align="center">

# ⚡ ZFinal

**A fast, production-hardened web framework for Zig**

*Inspired by JFinal — minimal API, maximal performance*

[![Zig](https://img.shields.io/badge/Zig-0.17.0-orange.svg)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-142%20passing%2C%200%20leaks-brightgreen.svg)]()
[![Production](https://img.shields.io/badge/production--readiness-92%25-green.svg)](PRODUCTION_AUDIT.md)

**English** | [中文文档](README_CN.md)

</div>

---

## What is ZFinal?

ZFinal is a **lightweight, high-performance web framework** for Zig 0.17. It provides routing, ORM, plugins, templating, and a rich utility toolkit — all in idiomatic Zig with minimal ceremony. Fiber-based async I/O with zero heap allocation per connection.

```zig
const zfinal = @import("zfinal");

pub fn main() !void {
    var app = zfinal.ZFinal.init(std.heap.page_allocator);
    defer app.deinit();

    try app.get("/", index);
    try app.start();
}

fn index(ctx: *zfinal.Context) !void {
    try ctx.renderJson(.{ .message = "Hello, ZFinal!" });
}
```

---

## Production Readiness

| Status | Dimension | Score |
|--------|-----------|-------|
| ✅ | Build Stability | 95% |
| ✅ | Security | 90% |
| ✅ | Memory Safety | 88% |
| ✅ | Correctness | 88% |
| ✅ | Observability | 85% |
| ✅ | Concurrency | 85% |
| ✅ | Testability | 85% |
| ✅ | Code Quality | 85% |
| 🟡 | Documentation | 60% |
| 🟡 | Examples | 82% |
| **→** | **Overall** | **88%** |

See [PRODUCTION_AUDIT.md](PRODUCTION_AUDIT.md) for the full assessment (51 findings, all critical/high resolved).

---

## Project Structure

```
src/
├── core/           # Fiber-based async server, router, context, session, logger, metrics
├── db/             # Database abstraction, connection pool, ORM, SQLite + PG + MySQL drivers
├── plugin/         # Plugin system (cache, cron — stable; others experimental)
├── interceptor/    # AOP interceptors (auth, CORS, logging, CSRF token)
├── token/          # CSRF token generation and validation
├── captcha/        # CAPTCHA generation (numeric, alpha, math)
├── template/       # Template engine (variables, loops, conditions, layouts)
├── kit/            # 17 utility kits (string, hash, json, http, file, validate, ...)
├── i18n/           # Internationalization with pluralization
├── upload/         # Multipart file upload parser
├── websocket/      # WebSocket server and connection manager
├── generator/      # Code generation utilities
├── validator/      # Request data validation
├── config/         # Configuration loader (.ini, .json)
├── io_instance.zig # Global IO instance (Zig 0.16 IO reform)
└── main.zig        # Module entry point — exports all public API
```

---

## Quick Start

### Build from source

```bash
git clone https://github.com/chy3xyz/zfinal.git
cd zfinal
zig build                  # Build framework + all examples
zig build test             # Run 107 unit tests
zig build test -Ddriver_pg=true -Ddriver_mysql=true  # All drivers
zig build test-db           # DB integration tests
```

### Run an example

```bash
zig build run-hello        # Hello-world demo
zig build run-blog         # Blog with SQLite
zig build run-htmx         # HTMX interactive app
zig build run-production   # Production example (logging, metrics, CSRF)
```

### Add to your project

```bash
# Zig package manager (recommended)
zig fetch --save https://github.com/chy3xyz/zfinal/archive/refs/tags/v0.6.0.tar.gz
```

In your `build.zig`:

```zig
const zfinal_dep = b.dependency("zfinal", .{ .target = target, .optimize = optimize });
const zfinal_mod = zfinal_dep.module("zfinal");

const exe_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{.{ .name = "zfinal", .module = zfinal_mod }},
});
exe_mod.link_libc = true;
exe_mod.linkSystemLibrary("sqlite3", .{});
```

In your `build.zig.zon`:

```zon
.dependencies = .{
    .zfinal = .{
        .url = "https://github.com/chy3xyz/zfinal/archive/refs/tags/v0.6.0.tar.gz",
        .hash = "...", // auto-filled by `zig fetch`
    },
},
```

Or use local path for development:

```zon
.zfinal = .{ .path = "../zfinal" },
```

---

## Core Capabilities

### Routing + Interceptors

```zig
// HTTP methods with path parameters
try app.get("/users/:id", showUser);
try app.post("/users", createUser);
try app.put("/users/:id", updateUser);
try app.delete("/users/:id", deleteUser);

// Route groups with shared prefix
var api = zfinal.RouteGroup.init(&app, "/api");
try api.get("/health", healthHandler);

// Global interceptors (auth, CORS, logging, rate limiting)
try app.addGlobalInterceptor(zfinal.CORSInterceptor);
```

### Database + ORM

```zig
const User = struct { id: ?i64, name: []const u8, email: []const u8 };
const UserModel = zfinal.Model(User, "users");

// Connection pool with health checks
var pool = zfinal.ConnectionPool.init(allocator, config, 10);

// CRUD with parameterized queries (SQL injection safe)
const users = try UserModel.findAll(&db, allocator);
var user = UserModel.Instance{ .data = User{ .name = "Alice", .email = "alice@example.com" } };
try user.save(&db);
try user.delete(&db);
```

### Security

```zig
// CSRF token protection
var token_mgr = zfinal.TokenManager.init(allocator);
const token = try token_mgr.generate();          // 32-byte random, Base64-encoded
const valid = try token_mgr.validate(token);     // One-time use, auto-expiry

// Rate limiting (real socket address, no spoofable headers)
var limiter = zfinal.RateLimitHandler.init(allocator);
limiter.max_requests = 100;                       // Per 60s window
try limiter.handle(ctx);

// CAPTCHA (numeric, alpha, alphanumeric, math)
var captcha_mgr = zfinal.CaptchaManager.init(allocator);
const captcha = try captcha_mgr.generate(.numeric, session_id);
```

### Structured Logging + Observability

```zig
// Structured logger with compile-time level filtering
var logger = zfinal.Logger.init(allocator);
logger.setLevel(.info);
logger.prefix = "myapp";
zfinal.initGlobalLogger(logger);

zfinal.getLogger().info("request handled", .{
    zfinal.Field{ .key = "method", .value = .{ .string = "GET" } },
    zfinal.Field{ .key = "status", .value = .{ .int = 200 } },
});

// Health endpoint with metrics
var metrics = zfinal.Metrics.init(allocator);
metrics.recordRequest(200);
const uptime = metrics.uptime();
```

**Build with log level:** `zig build -Dlog-level=debug|info|warn|err`

### Template Engine

```html
{# Layout inheritance #}
{% extends "layout.html" %}

{% block content %}
  <h1>{{ title }}</h1>
  <ul>
  {% for item in items %}
    <li>{{ item.name }} — {{ item.price | upper }}</li>
  {% endfor %}
  </ul>
  {% include "footer.html" %}
{% endblock %}
```

---

## Plugin Maturity

| Plugin | Status | Description |
|--------|--------|-------------|
| Cache (memory) | ✅ Stable | In-memory cache with TTL, thread-safe |
| Cron | ✅ Stable | Cron expression parser, job scheduling |
| PostgreSQL | 🔧 Opt-in | Full libpq driver in `drivers/` — requires `libpq` |
| MySQL | 🔧 Opt-in | Full mysqlclient driver in `drivers/` — requires `libmysqlclient` |
| Cache (Redis) | ✅ Stable | Full Redis client with RESP protocol over TCP |
| MQTT | 🟡 Stub | MQTT 3.1.1 client — IoT protocol, not core framework |
| Agent (MCP) | 🔧 Experimental | Model Context Protocol agent — early development |
| P2P | 🔧 Experimental | Peer-to-peer networking — early development |
| DID | 🔧 Experimental | Decentralized Identity — early development |

**Stable plugins** are production-ready. **Stub** plugins have their API defined but lack full implementation. **Experimental** plugins are under active development and not recommended for production use.

---

## Utility Kits (17 modules)

| Kit | Purpose |
|-----|---------|
| `StrKit` | String operations (split, join, trim, case) |
| `HashKit` | MD5, SHA256, Base64 |
| `JsonKit` | JSON parse / stringify |
| `DateKit` | Date formatting, leap year, month days |
| `TimeKit` | Timestamps, sleep, ISO 8601 |
| `FileKit` | Read/write/copy/delete, path sandboxing |
| `PathKit` | Path join, basename, dirname, resolve |
| `HttpKit` | MIME types, status codes, browser detection |
| `UrlKit` | URL encode/decode |
| `ArrayKit` | Contains, unique, sum, filter, map |
| `RandomKit` | CSPRNG-backed random int, float, UUID, shuffle |
| `RegexKit` | Regex match, email/IP/phone validation |
| `ValidateKit` | Email, phone, IP, password strength |
| `NumberKit` | Parse, clamp, format |
| `FormatKit` | File size, number formatting |
| `SysKit` | System info, environment |
| `CacheKit` | Simple key-value cache |

---

## Architecture

ZFinal uses a **fiber-based async I/O model** built on `std.Io.Threaded`:

```
┌─────────────────────────────────────────┐
│  Io.Threaded (kqueue / io_uring)        │
│  ┌─────────────────────────────────┐    │
│  │  acceptLoop (fiber)             │    │
│  │  ┌──────────────────────────┐   │    │
│  │  │ handleConn (fiber)       │   │    │
│  │  │  dispatch → router → ctx │   │    │
│  │  └──────────────────────────┘   │    │
│  │  handleConn (fiber) × N         │    │
│  └─────────────────────────────────┘    │
└─────────────────────────────────────────┘
```

- **Zero heap allocation per connection** — all request state is stack-resident
- **Keep-alive** — up to 100 requests per connection
- **Backpressure** — 503 response when `max_connections` exceeded
- **Accept retry** — exponential backoff on transient errors

## Performance

Benchmark characteristics (M1 Pro, 8 cores, localhost):

| Scenario | Throughput | Latency (P50) | Memory |
|----------|-----------|---------------|--------|
| Hello world (JSON) | ~25,000 req/s | 0.4ms | ~12MB |
| SQLite read (cached) | ~15,000 req/s | 0.6ms | ~14MB |
| SQLite write (pooled) | ~5,000 req/s | 1.2ms | ~14MB |
| 1,000 concurrent keep-alive | ~30,000 req/s | 0.5ms | ~18MB |

Key performance properties:

- **Zero GC pauses** — no garbage collector
- **Fiber-based concurrency** — kqueue (macOS) / io_uring (Linux), no thread-per-connection overhead
- **Stack-allocated request handling** — no heap allocations per request
- **Compile-time optimization** — log levels, SQL templates, route parsing
- **Connection pooling** — database connection reuse with health checks

For detailed benchmarks, run: `zig build run-bench`

---

## Roadmap

### v0.3 (current) — Production Hardening ✅

Security hardening, structured logging, health endpoints, concurrency fixes, template engine, i18n, cron, 90 tests.

### v0.4 (next) — Ecosystem & Polish

- [x] Redis client network implementation (RESP protocol, TCP)
- [ ] Template engine: advanced filters, macros
- [ ] WebSocket: frame fragmentation, ping/pong
- [ ] Admin dashboard (metrics, health, recent errors)
- [ ] Docker deployment example
- [ ] API reference documentation (`zig build docs`)

### v1.0 — Stable Release

- [ ] Stable API surface (no breaking changes without major version)
- [x] PostgreSQL and MySQL driver implementations (opt-in, in `drivers/`)
- [ ] Comprehensive integration test suite
- [ ] Production deployment guide
- [ ] gRPC support (optional module)

---

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/amazing`
3. Make changes, run tests: `zig build test`
4. Commit: `git commit -m 'feat: add amazing feature'`
5. Push and open a Pull Request

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines.

---

## License

MIT — see [LICENSE](LICENSE) for details.

---

<div align="center">
Made with ❤️ by the ZFinal Team
</div>
