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
- Interceptor factories take **caller-owned** `*const Cfg` (no `heapCfg` / no static `var`):
  `JwtAuthConfig`, `TokenInterceptorConfig`, `CorsAllowlistConfig`, `SecurityHeadersConfig`,
  `stock.BodyLimitConfig`, …
- Prefer `before_ud` + `userdata` for **all** interceptors (zero-config factories pass `_`);
  plain `before`/`after` are a compatibility fallback. Dispatch uses `runBefore`/`runAfter` everywhere.
- Migrate old generated handlers: `zf check --heal` injects `failHttp` / `extract.requireParamInt`
  (or regenerate with `zf crud:sql`).

```zig
var jwt_cfg: zfinal.JwtAuthConfig = .{ .secret = secret, .opts = .{ .leeway_sec = 30 } };
try app.addGlobalInterceptor(zfinal.createJwtAuthInterceptorWithOptions(&jwt_cfg));
```

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
| `createBodyLimitInterceptor(*BodyLimitConfig)` | Cap `ctx.max_body_size` |
| `createTimeoutInterceptor(*TimeoutConfig)` | `ctx.setTimeoutMs` |
| `createCompressionInterceptor(*CompressionConfig)` | Per-request gzip on/off |
| `createTraceInterceptor()` | Access log after handler |

```zig
var bl: zfinal.stock.BodyLimitConfig = .{ .max_bytes = 1024 * 1024 };
try app.addGlobalInterceptor(zfinal.stock.createBodyLimitInterceptor(&bl));
```

Server default: `ServerConfig.compress_responses` (default true).

### Cache interceptor

`createCacheInterceptor(*CacheInterceptorConfig)`: GET hit short-circuits. **After-store only works with `oneshot.capture`** (no TCP body buffer). Production HTTP caching: handler + `CacheKit`, or reverse-proxy cache.

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
| `oneshot.capture(...)` | **None** (capture buffer) | Handler only `render*` + path params / State |
| `oneshot.captureWith(..., headers, body)` | **None** + mock headers/body | JWT/CSRF/extract needing `Authorization` / JSON body |
| `oneshot.against` / `fetch` | TCP | Full `std.http.Server.Request` (multipart, etc.) |

```zig
var res = try zfinal.oneshot.capture(a, &router, .GET, "/ping", .{});
defer res.deinit();

var auth = try zfinal.oneshot.captureWith(a, &router, .GET, "/me", .{}, &.{
    .{ .name = "Authorization", .value = "Bearer …" },
}, null);
defer auth.deinit();
```

**Keep-alive:** production still defaults `force_connection_close=true` until zig#25017 is fixed — see `doc/reverse_proxy.md` §9.

`zf openapi` emits `components.schemas.HttpError`, `JsonObject`, `JsonOk`, plus
per-entity DTOs from:
- ORM `pub const Name = struct { … }` → `Name` / `NameInput`
- zent `Schema("Name", .{ .fields = &.{ field.String("…"), … } })` → same

Routes under `/users` / `/products` `$ref` those DTOs when names match.

## DI boundary

- **Do:** `ports` + adapters + `setState` / Extension  
- **Don't:** global service locator, handler → DB skip service, runtime plugin bag as DI
