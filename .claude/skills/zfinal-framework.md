---
name: zfinal-framework
description: Contribute to the ZFinal framework itself. Add features, fix bugs, optimize modules, write tests. Use when asked to improve ZFinal's core, plugins, drivers, or documentation. NOT for building applications with ZFinal — use zfinal-app for that.
---

# ZFinal Framework Developer

You are contributing to the ZFinal web framework itself (not building an app with it).

## Codebase Map

| Directory | Responsibility |
|-----------|---------------|
| `src/core/` | Server, Router, Context, Session, Logger, Metrics, Shutdown, ThreadPool |
| `src/db/` | DB abstraction, SQLite/PG/MySQL drivers, ConnectionPool, ORM, SQL templates |
| `src/plugin/` | Cache, Cron, Redis (stable); MQTT, P2P, DID, Agent (experimental) |
| `src/kit/` | 17 utility kits (no framework dependencies) |
| `src/interceptor/` | Auth, CORS, Logging, CSRF interceptor |
| `src/token/` | CSRF token generation and validation |
| `src/captcha/` | CAPTCHA generation (numeric, alpha, math) |
| `src/template/` | Template engine (parsing, rendering, blocks) |
| `src/websocket/` | WebSocket frames, connection management |
| `src/validator/` | Input validation |
| `src/i18n/` | Internationalization, pluralization |
| `src/main.zig` | Public API exports |

## Development Workflow

```bash
zig build                 # Build everything
zig build test            # Run all 90 tests
zig test src/main.zig -lSQLite3 -lc  # Run with direct zig test
```

## Adding a New Feature

1. Create module in appropriate directory
2. Add tests at bottom of module file
3. Export from `src/main.zig` with `pub const MyType = @import("path.zig").MyType;`
4. Run `zig build test` — all tests must pass
5. Update README plugin maturity table if applicable

## Writing Tests

```zig
test "feature name: specific scenario" {
    const allocator = std.testing.allocator;
    // ... setup, exercise, verify
    try std.testing.expectEqual(expected, actual);
}
```

## Zig 0.16 Patterns

- IO instance from `@import("../io_instance.zig")`
- `std.ArrayList(T).empty` for initialization, `.deinit(allocator)` for cleanup
- `std.Io.Mutex.init` (const, no parens)
- `std.Io.Timestamp.now(io, .real).toSeconds()` for timestamps
- `std.Io.Writer.Allocating.init(allocator)` for string building
- `std.json.parseFromSlice(T, allocator, json, .{})` for JSON parsing
- `std.fmt.bufPrint` returns `![]const u8` (error on overflow)

## Plugin Maturity Tiers

- **Stable**: Cache (memory), Cron, Redis — production-ready, full tests
- **Opt-in**: PostgreSQL, MySQL drivers — require native C libraries
- **Experimental**: MQTT, P2P, DID, Agent — functional but not recommended for production

## Performance Rules

- Zero heap allocation in hot path (handleConn uses stack buffers only)
- Fiber-based concurrency — never block in a fiber
- Use `std.atomic.Value` for shared counters, not mutexes when possible
- `defer` for all cleanup (even in error paths)
- `errdefer` for allocation cleanup when subsequent calls may fail
