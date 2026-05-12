# AGENTS.md — ZFinal AI Development Guide

This file provides guidance for AI coding agents (Claude Code, etc.) working with ZFinal.

## Project Overview

ZFinal is a production-hardened Zig web framework (v0.3.0, Zig 0.16, ~94% readiness). Fiber-based async server, ActiveRecord ORM, plugin system, 17 utility kits.

## Quick Commands

```bash
zig build                 # Build framework + all examples
zig build test            # Run 90 tests (88 pass, 2 skip)
zig build run-hello       # Hello-world demo
zig build run-blog        # Blog with SQLite
zig build run-htmx        # HTMX interactive app
zig build run-production  # Production example
zig build run-ws          # WebSocket demo
zig build install-zf      # Build CLI tool -> zig-out/bin/zf
```

## Architecture

```
src/
├── core/    # Server (fiber-based), Router, Context, Session, Logger, Metrics, Shutdown
├── db/      # DB wrapper, SQLite/PG/MySQL drivers, ConnectionPool, ORM, SQL templates
├── plugin/  # Cache (stable), Cron (stable), Redis (stable), MQTT/P2P/DID/Agent (experimental)
├── kit/     # 17 utilities: str, hash, json, file, validate, regex, random (CSPRNG), etc.
├── interceptor/  # Auth, CORS, Logging, CSRF token interceptors
├── token/    # CSRF token generation/validation (32-byte random, Base64)
├── captcha/  # Numeric/alpha/alphanumeric/math captcha
├── template/ # Template engine (vars, loops, conditions, includes, extends, layouts)
├── i18n/     # Internationalization with pluralization
├── websocket/# WebSocket with ping/pong, close handshake
└── main.zig  # Public API exports
```

## Pattern: Create a ZFinal Application

```zig
const std = @import("std");
const zfinal = @import("zfinal");

pub fn main() !void {
    var app = zfinal.ZFinal.init(std.heap.page_allocator);
    defer app.deinit();

    // Routes
    try app.get("/", indexHandler);
    try app.post("/api/users", createUser);

    // Global interceptors
    try app.addGlobalInterceptor(zfinal.CORSInterceptor);

    // Start fiber-based async server
    try app.start();
}

fn indexHandler(ctx: *zfinal.Context) !void {
    try ctx.renderJson(.{ .message = "Hello, ZFinal!" });
}
```

## Pattern: Handler with Database

```zig
fn listUsers(ctx: *zfinal.Context) !void {
    const db = try pool.acquire();
    defer pool.release(db) catch {};

    const sql = "SELECT * FROM users ORDER BY id";
    var result = try db.queryParams(@ptrCast(sql), &.{});
    defer result.deinit();
    // ... iterate result
}
```

## Pattern: CSRF-Protected POST

```zig
var token_mgr = zfinal.TokenManager.init(allocator);
defer token_mgr.deinit();

fn showForm(ctx: *zfinal.Context) !void {
    const token = try token_mgr.generate();
    defer allocator.free(token);
    // Render form with hidden <input name="csrf_token" value="{s}">
}

fn handleSubmit(ctx: *zfinal.Context) !void {
    const submitted = try ctx.getPara("csrf_token") orelse return error.MissingToken;
    if (!try token_mgr.validate(submitted)) {
        ctx.res_status = .forbidden;
        return try ctx.renderJson(.{ .err = "Invalid CSRF token" });
    }
    // Process form...
}
```

## Pattern: Structured Logging

```zig
var logger = zfinal.Logger.init(allocator);
logger.setLevel(.info);
logger.prefix = "myapp";
zfinal.initGlobalLogger(logger);

zfinal.getLogger().info("request handled", .{
    zfinal.Field{ .key = "method", .value = .{ .string = "GET" } },
    zfinal.Field{ .key = "status", .value = .{ .int = 200 } },
});

// Build with log level: zig build -Dlog-level=debug
```

## Pattern: Graceful Shutdown

```zig
zfinal.shutdown.registerHandlers();
// ... start server, check shutdown.isShuttingDown() in loops
```

## Key Rules

1. **Allocator**: Always pass allocator explicitly, never use global/static
2. **Cleanup**: Every `init()` needs a `defer x.deinit()` 
3. **Context**: Created per-request, `defer ctx.deinit()` frees all resources
4. **SQL safety**: Use `execParams`/`queryParams` with bound params. Never concatenate user input into SQL. `findWhere` requires `comptime` WHERE clause.
5. **CSRF**: Use `TokenManager` for all state-changing endpoints
6. **Error handling**: Handlers return `!void`, errors become 500 with structured log
7. **Plugin deps**: Cache/Cron/Redis are stable. MQTT/P2P/DID/Agent are experimental.

## Zig 0.16 Specifics

- IO: `std.Io` (capital I), use `io_instance.zig` for global instance
- ArrayList: `.empty` (no allocator), `deinit(allocator)` 
- Mutex: `std.Io.Mutex.init` (no parens), `lock(io)`/`unlock(io)`
- Format: `"{}" ` for errors, `"{s}"` for slices, `"{d}"` for integers
- Server accept: returns `Stream` (no `.address` field, use `getpeername` for remote IP)
