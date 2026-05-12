<div align="center">

# ⚡ ZFinal

**A fast, production-hardened web framework for Zig**

*Inspired by JFinal — minimal API, maximal performance*

[![Zig](https://img.shields.io/badge/Zig-0.16.0-orange.svg)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-90%20passing-brightgreen.svg)]()
[![Production](https://img.shields.io/badge/production--readiness-88%25-yellow.svg)](PRODUCTION_AUDIT.md)

**English** | [中文文档](README_CN.md)

</div>

---

## What is ZFinal?

ZFinal is a **lightweight, high-performance web framework** for Zig 0.16. It provides routing, ORM, plugins, templating, and a rich utility toolkit — all in idiomatic Zig with minimal ceremony.

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
├── core/           # HTTP server, router, context, session, logger, metrics
├── db/             # Database abstraction, connection pool, ORM, SQLite driver
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
zig build test             # Run 90 tests
```

### Run an example

```bash
zig build run-hello        # Hello-world demo
zig build run-blog         # Blog with SQLite
zig build run-htmx         # HTMX interactive app
zig build run-production   # Production example (logging, metrics, CSRF)
```

### Add to your project

In your `build.zig`:

```zig
const zfinal_mod = b.addModule("zfinal", .{
    .root_source_file = b.path("path/to/zfinal/src/main.zig"),
    .target = target,
    .optimize = optimize,
});
zfinal_mod.link_libc = true;
zfinal_mod.linkSystemLibrary("sqlite3", .{});

// With log level
// zig build -Dlog-level=debug
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

## Performance

ZFinal is built on Zig's native compilation and zero-cost abstractions. Key performance properties:

- **Zero GC pauses** — no garbage collector
- **Stack-allocated request handling** — minimal heap pressure (async server path)
- **Compile-time optimization** — log levels, SQL templates, route parsing
- **Connection pooling** — SQLite connection reuse with health checks

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
