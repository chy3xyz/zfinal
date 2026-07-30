# HTTP ergonomics (Axum-inspired)

Related: [smart_routing.md](smart_routing.md) · [progressive_architecture.md](progressive_architecture.md) · ADR-011 · ADR-012

## Layer order

```
global interceptors → route interceptors → handler → after (reverse)
```

- Prefer `return error.Unauthorized` (etc.) from `before` — `dispatch` maps to JSON.
- `return false` only when you **already** wrote a response (e.g. CORS preflight).
- Do not mix: never `renderJson` then `return error.*` (double-write guarded by `response_started`).
- Rate limit / demo Auth / `ParamExt` also return `HttpError` (no hand-rolled body).
- After any successful `respond` (`render*`, `renderFile`, `renderCsv`, `redirect`, SSE start), `markResponded()` sets `response_started` so a second render is a no-op.

## State (app-wide)

```zig
app.setState(App, &app_state);
const st = try ctx.state(App);
```

One type per app. Ports examples: `examples/ports-l2`, `ports-l3`.

## Extension (request-scoped)

```zig
try ctx.setExt(zfinal.extension.JwtIdentity, .{ .sub = "u", .role = "admin" });
if (ctx.ext(zfinal.extension.JwtIdentity)) |jwt| { _ = jwt.sub; }
```

JWT interceptor sets `JwtIdentity` after attrs. ≠ State.

## Extractors / HttpError / Tenant

See prior sections — `extract.*`, `HttpError` table, comptime `tenant.app_id`.

## Stock layers (`zfinal.stock`)

| Helper | Role |
|--------|------|
| `createBodyLimitInterceptor(n)` | Cap `ctx.max_body_size` |
| `createTimeoutInterceptor(ms)` | `ctx.setTimeoutMs` |
| `createCompressionInterceptor(bool)` | Per-request gzip on/off |
| `createTraceInterceptor()` | Access log after handler |

Server default: `ServerConfig.compress_responses` (default true).

## Fallback / merge

```zig
try app.setFallback(spaHandler);           // unmatched path (not 405)
try app.merge(&.{ users.register, orders.register });
```

## SSE + client gone

```zig
var bw = try ctx.renderSSE();
defer bw.end() catch {};
ctx.sseWrite(&bw, chunk) catch |err| {
    if (err == error.WriteFailed or ctx.isClientGone()) return; // stop
    return err;
};
```

`WriteFailed` in `dispatch` does **not** attempt a 500 body.

## Oneshot

| API | Transport | Use when |
|-----|-----------|----------|
| `oneshot.capture(allocator, router, method, path, state)` | **None** (capture buffer) | Handler only `render*` + path params / State |
| `oneshot.against` / `fetch` | TCP | Needs headers/body / real `req` |

```zig
var res = try zfinal.oneshot.capture(a, &router, .GET, "/ping", .{});
defer res.deinit();
```

## OpenAPI

`zf openapi` emits `components.schemas.HttpError` and `$ref`s on 400/401/404/422/429.

## DI boundary

- **Do:** `ports` + adapters + `setState` / Extension  
- **Don't:** global service locator, handler → DB skip service, runtime plugin bag as DI
