---
name: zfinal-debug
description: ZFinal compilation error → fix-pattern lookup. Use when an AI agent encounters a Zig compile error or runtime error in a ZFinal project, especially if it involves ConnectionPool, server.shutdown, pthread, mysql_real_connect, std.Thread.spawn, or std.Io.Group. Triggers on errors like "Lost connection", "assert(g.token.raw == null)", "PoolTimeout", "no field named acquire in *ConnectionPool", "unable to resolve comptime value", "expected type 'T', found '*T'", or any compile/runtime error during `zig build`, `zig build test`, or runtime server start.
---

# ZFinal Debug Skill

> **🛑 Quick lookup table for compile/runtime errors.**
> Match your error → read the fix pattern → apply → rebuild.

## How to use this skill

1. Find your error in the table below.
2. Read the **Fix** column.
3. Apply the fix in code (don't change anything outside the fix zone).
4. `zig build` → confirm green.
5. If new error: read the section below the table.

---

## Compile Error Lookup

### DB / Connection / Pool

| Error | Cause | Fix |
|-------|-------|-----|
| `expected type 'T', found '*T'` (deps.pool) | `pool` is now `*ConnectionPool`, not `ConnectionPool` | Change `pub var pool: zfinal.ConnectionPool` → `pub var pool: *zfinal.ConnectionPool`. Add `getPool()` function. |
| `no field or member function named 'acquire' in '*db.pool.ConnectionPool'` | Old codegen uses `pool_ref = &deps.pool` pattern | Run: `python3 tools/regen_getters.py examples/<proj>/src` to rewrite generated handlers. |
| `unable to resolve comptime value` in `getPool()` | `pool` is a runtime var, Zig 0.17 requires explicit pointer cast | Use `@as(*ConnectionPool, @ptrCast(&pool))` instead of `return pool;` |
| `PoolTimeout` at runtime | No available connection within 30s | Increase `acquire_timeout_ms` or check `pool.current_connections` via `/debug/pool`. |
| `mysql_real_connect: Lost connection` in worker thread | TLS/errno corruption from `std.Thread.spawn` on aarch64-macos | Use `zfinal.Worker.Thread.spawn(ctx.run, ctx)` (raw `pthread_create`) instead. |

### Server / Shutdown

| Error | Cause | Fix |
|-------|-------|-----|
| `assert(g.token.raw == null)` panic | `group.cancel(io)` with active fibers | v0.10.7+ already fixed via drain loop. If older: replace with `group.await(io)` + active_conns poll. |
| Server hangs after SIGTERM | Shutdown signal not registered | Add `zfinal.shutdown.registerHandlers();` to your `main()` before `app.start()`. |
| `std.Io.Duration.fromMilliseconds` not found | Renamed in Zig 0.17 | Use `std.Io.Duration{ .nanos = ms * 1_000_000 }` directly. |

### Zig 0.17 Migration

| Error | Cause | Fix |
|-------|-------|-----|
| `@cImport` removed | Use `b.addTranslateC` in build.zig | Define C imports as separate modules, add via `addImport("c_x", x_mod)`. |
| `std.fmt.bufPrintZ` not found | Renamed | Use `bufPrint` + manual `buf[len] = 0`. |
| `allocator.dupeZ` not found | Renamed | Use `allocSentinel` + `@memcpy`. |
| `callconv(.C)` not found | Lowercase in 0.17 | Use `callconv(.c)`. |
| `var x` warning "never mutated" | Strict 0.17 checks | Use `const x` if not reassigned. |
| `extern "c"` fn not found | Missing std.c declaration | Add manual `extern "c" fn pthread_mutex_init(...) c_int;` declaration. |

### Codegen / `zf`

| Error | Cause | Fix |
|-------|-------|-----|
| `zf crud:sql` fails to parse | SQL syntax error | Check for missing `;` after `CREATE TABLE`, missing `NOT NULL`, etc. |
| Generated files have stale `pool_ref` | `zf` codegen output mismatch | Re-run `zf crud:sql schema.sql --force` (force regen). |
| `// @generated` file modified by AI | AI should not edit these | Re-run `zf crud:sql schema.sql` to regenerate. |

---

## Runtime Error Lookup

### Network

| Error | Cause | Fix |
|-------|-------|-----|
| `connection refused` on localhost:8080 | Server not started or wrong port | Check `app.config.port` matches; check firewall. |
| `connection reset by peer` on HTTP request | Client closed before response | Normal; wrap handler with try/catch for logging. |
| `tls handshake failure` | HTTPS server not configured | v0.10.x: HTTP only. Use nginx/Caddy as reverse proxy. |

### Database

| Error | Cause | Fix |
|-------|-------|-----|
| `Access denied for user` | MySQL credentials wrong | Check `DBConfig.user` / `password` / `host` / `port`. |
| `Unknown database` | DB not created | `CREATE DATABASE <name>;` first. |
| `Table doesn't exist` | Schema not migrated | Run schema.sql, or use `zf crud:dsn` to reverse-gen. |
| SQLite `database is locked` | Concurrent writes | Use ConnectionPool with max_connections=1 for SQLite. |

### Plugin

| Error | Cause | Fix |
|-------|-------|-----|
| `RedisClient.connect failed` | Redis not running | Start redis-server, check `redis_host`/`redis_port`. |
| `MQTTPlugin: connection lost` | Broker down | Check broker address, network. |
| `WechatPlugin: officialAccount init failed` | Wrong app_id/secret | Check WeChat backend credentials. |

---

## Common Fix Recipes

### Recipe 1: Update generated code to new ConnectionPool API

```bash
# After v0.10.4, ConnectionPool.init() returns *ConnectionPool
# Auto-fix existing generated handlers:
python3 << 'PYEOF'
import os, re
ROOT = "examples/<proj>/src"
for dp, _, fns in os.walk(ROOT):
    for fn in fns:
        if not fn.endswith(".zig"): continue
        p = os.path.join(dp, fn)
        with open(p) as f: c = f.read()
        orig = c
        c = re.sub(r'^(\s*)const\s+pool_ref\s*=\s*&?@import\(([^)]+)\)\.pool;\s*$',
                   r'\1const pool = @import(\2).getPool();', c, flags=re.M)
        c = re.sub(r'^(\s*)const\s+token_ref\s*=\s*&?@import\(([^)]+)\)\.tokenMgr;\s*$',
                   r'\1const tokenMgr = @import(\2).getTokenMgr();', c, flags=re.M)
        c = re.sub(r'^(\s*)const\s+limit_ref\s*=\s*&?@import\(([^)]+)\)\.rateLimiter;\s*$',
                   r'\1const rateLimiter = @import(\2).getRateLimiter();', c, flags=re.M)
        c = c.replace("pool_ref.", "pool.").replace("token_ref.", "tokenMgr.").replace("limit_ref.", "rateLimiter.")
        if c != orig:
            with open(p, 'w') as f: f.write(c)
            print(f"fixed: {p}")
PYEOF

# Then update your deps.zig:
# pub var pool: *zfinal.ConnectionPool = undefined;
# pub fn getPool() *zfinal.ConnectionPool { return @as(*zfinal.ConnectionPool, @ptrCast(&pool)); }
```

### Recipe 2: Replace std.Thread.spawn with Worker.Thread.spawn

```zig
// Old (broken on aarch64-macos):
const handle = try std.Thread.spawn(allocator, ctx.run, .{ctx});

// New (uses pthread_create, no TLS bug):
const handle = try zfinal.Worker.Thread.spawn(
    struct {
        fn run(raw: *anyopaque) callconv(.c) ?*anyopaque {
            const self: *Ctx = @ptrCast(@alignCast(raw));
            self.run();
            return null;
        }
    }.run,
    ctx,
);
```

### Recipe 3: Register graceful shutdown

```zig
pub fn main(init: std.process.Init) !void {
    zfinal.io_instance.init(init);
    const allocator = init.gpa;

    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();

    // Add routes
    try app.get("/", index);
    try app.get("/api/data", getData);

    // v0.10.7+: register SIGTERM/SIGINT handlers
    zfinal.shutdown.registerHandlers();

    try app.start();
}
```

---

## Quick Decision Tree

```
Build error?
├─ mentions pool, deps, @import → see DB / Connection section
├─ mentions cancel, await, group → see Server / Shutdown section
├─ mentions @cImport, bufPrintZ, dupeZ, callconv → see Zig 0.17 Migration
└─ mentions @generated, zf → see Codegen section

Runtime error?
├─ "Lost connection" + child thread → aarch64-macos TLS bug → Recipe 2
├─ Connection refused / reset / timeout → Network section
└─ Access denied / Unknown database → Database section
```

---

## Don't Fix These (Intentional)

Some "errors" are by design:
- `error.SkipZigTest` in test blocks → test is documented as skipped
- `pointless discard` warnings on `_ =` → AI's intentional silence
- `var` vs `const` warnings in comptime blocks → `var` required for assignability

---

## Related Skills

- **zfinal-onboarding** — first read on starting a ZFinal task
- **zfinal-framework** — architecture overview
- **zfinal-app** — building a complete app
- **zfinal-health** — health check scoring