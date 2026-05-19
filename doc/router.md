# ZFinal Router

## Route Registration

```zig
const zfinal = @import("zfinal");

var app = zfinal.ZFinal.init(allocator);
defer app.deinit();

// HTTP method-specific
try app.get("/", indexHandler);
try app.post("/users", createUser);
try app.put("/users/:id", updateUser);
try app.delete("/users/:id", deleteUser);
try app.patch("/users/:id", patchUser);

// Any method
try app.addRoute("/health", healthHandler);
```

## Path Parameters

Use `:name` syntax to capture path segments.

```zig
// /users/42 → ctx.getPathParam("id") returns "42"
try app.get("/users/:id", showUser);

// /posts/7/comments/15 → two params
try app.get("/posts/:post_id/comments/:comment_id", showComment);

fn showUser(ctx: *zfinal.Context) !void {
    const id_str = ctx.getPathParam("id") orelse return error.BadRequest;
    const id = try std.fmt.parseInt(i64, id_str, 10);
    // ...
}
```

## Route Groups

```zig
var api = zfinal.RouteGroup.init(&app, "/api/v1");
defer api.deinit();

try api.get("/users", listUsers);
try api.post("/users", createUser);
// Registers: /api/v1/users

var admin = zfinal.RouteGroup.init(&app, "/admin");
try admin.get("/dashboard", adminDashboard);
// Registers: /admin/dashboard
```

## Interceptors (Middleware)

```zig
const auth = zfinal.AuthInterceptor.init(allocator, "secret-key");
try app.addGlobalInterceptor(auth);

// Route-specific interceptors
var chain = zfinal.InterceptorChain.init(allocator);
defer chain.deinit();
try chain.add(loggingInterceptor);
try app.getWithInterceptors("/secure", handler, &.{rateLimitInterceptor});
```

### Custom Interceptor

```zig
const myInterceptor = zfinal.Interceptor{
    .name = "custom",
    .before = struct {
        fn before(ctx: *zfinal.Context) !bool {
            // Return false to stop chain, true to continue
            return true;
        }
    }.before,
    .after = struct {
        fn after(ctx: *zfinal.Context) !void {
            // Run after handler completes
        }
    }.after,
};
```

### Built-in Interceptors

| Interceptor | Import | Purpose |
|------------|--------|---------|
| `LoggingInterceptor` | `interceptor/interceptor.zig` | Request logging |
| `AuthInterceptor` | `interceptor/interceptor.zig` | Auth header validation |
| `CORSInterceptor` | `interceptor/interceptor.zig` | CORS headers |
| `createPerformanceInterceptor` | `ext/interceptor.zig` | Timing |
| `createCacheInterceptor` | `ext/interceptor.zig` | Response caching |
| `createAccessLogInterceptor` | `ext/interceptor.zig` | Structured logging |
| `createExceptionInterceptor` | `ext/interceptor.zig` | Error recovery |
| `createTokenInterceptor` | `token/interceptor.zig` | CSRF token |

## Context API

```zig
fn handler(ctx: *zfinal.Context) !void {
    // Request
    const method = @tagName(ctx.req.head.method);
    const path = ctx.req.head.target;
    const qp = try ctx.getQueryParam("page");
    const fp = try ctx.getPara("field");      // form/multipart param
    const pp = ctx.getPathParam("id");         // route param

    // Response
    ctx.res_status = .ok;                      // default: 200
    try ctx.renderText("Hello");
    try ctx.renderJson(.{ .message = "ok" });
    try ctx.renderHtml("<h1>Hello</h1>");

    // Set header
    try ctx.setHeader("X-Custom", "value");
}
```

## Server Configuration

```zig
var config = zfinal.ServerConfig{
    .host = "0.0.0.0",
    .port = 8080,
    .thread_count = 0,          // 0 = auto (CPU count)
    .max_connections = 10000,
    .max_requests_per_conn = 100,
    .max_body_size = 10 * 1024 * 1024, // 10MB
};
app.setConfig(config);
try app.start();
```

## Graceful Shutdown

```zig
zfinal.shutdown.registerHandlers();
// Server accept loop checks zfinal.shutdown.isShuttingDown()
// and drains connections before exiting.
```
