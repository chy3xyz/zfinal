---
name: zfinal-framework
description: Improve ZFinal framework internals. Add features, fix bugs, optimize. NOT for building apps — use zfinal-app for that.
---

# ZFinal Framework Developer

## Codebase Map

```
src/core/       Server, Router, Context, Session, Logger, Metrics, Shutdown
src/db/         DB wrapper, SQLite/PG/MySQL drivers, ConnectionPool, ORM
src/plugin/     Cache, Cron, Redis (stable); MQTT/P2P/DID/Agent (experimental)
src/kit/        17 utilities (no framework deps)
src/interceptor/ Auth, CORS, Logging, CSRF
src/token/      CSRF token gen/validate (CSPRNG)
src/captcha/    CAPTCHA (numeric, alpha, math)
src/template/   Template engine (vars, loops, conditions, includes, extends)
src/websocket/  WS frames, connection mgr, ping/pong, fragmentation
src/validator/  Input validation
src/i18n/       Internationalization, pluralization
src/main.zig    Public API exports
tools/zf/       CLI tool + codegen
```

## Quick Commands

```bash
zig build               # Build everything
zig build test          # 90 tests
zig build install-zf    # Build CLI
```

## Adding a Feature

1. Create module in correct directory
2. Add tests at bottom
3. Export in `src/main.zig`
4. `zig build test` must pass
5. Update README plugin table if applicable

## Zig 0.16 Patterns

- `std.ArrayList(T).empty` + explicit allocator on all methods
- `std.Io.Mutex.init` (const, no parens)
- `std.Io.Timestamp.now(io, .real).toSeconds()`
- `std.json.parseFromSlice(T, allocator, json, .{})`
- Never `ArrayList.writer()` on `.empty` — use `allocPrint` + `appendSlice`
- `deinit(allocator)` everywhere
