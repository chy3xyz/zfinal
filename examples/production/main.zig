//! Production-oriented example: structured logging, auto Metrics,
//! CSRF on POST, rate-limit interceptor, JWT-protected route (iss/aud/rotation),
//! CORS allow-list, security headers, request ID, idle/read timeouts,
//! graceful shutdown.
//!
//! API routes: `src/modules/api/actions.zig` → `zf routes` → `routes.zig`.
//! App deps via `app.setState(AppState, …)` / `ctx.state(AppState)`.
//! See PRODUCTION_AUDIT.md deployment contract (contractual 9.8).

const std = @import("std");
const zfinal = @import("zfinal");
const api_handler = @import("src/modules/api/handler.zig");
const api_routes = @import("src/modules/api/routes.zig");
const interceptors = @import("src/interceptors.zig");

pub const log_level = "info";

var g_metrics: zfinal.Metrics = undefined;
var g_rate: *zfinal.RateLimitHandler = undefined;

fn probeProcessAlive() bool {
    return true;
}

pub fn main(init: std.process.Init) !void {
    zfinal.io_instance.init(init);
    const allocator = init.gpa;

    // Match container/orchestration: SIGTERM/SIGINT → drain with deadline.
    zfinal.shutdown.registerHandlers();

    var logger = zfinal.Logger.init(allocator);
    logger.setLevel(.info);
    logger.prefix = "zfinal";
    zfinal.initGlobalLogger(logger);
    zfinal.getLogger().infoFmt("Server starting up", .{});

    g_metrics = zfinal.Metrics.init(allocator);
    defer g_metrics.deinit();

    var app_state: api_handler.AppState = .{
        .token_mgr = undefined,
        .jwt_secret = "change-me-in-production-min-32-bytes!!",
    };
    if (std.c.getenv("JWT_SECRET")) |s| {
        app_state.jwt_secret = std.mem.span(s);
    }
    if (std.c.getenv("JWT_SECRET_PREVIOUS")) |s| {
        app_state.jwt_secret_prev = std.mem.span(s);
    }
    if (std.c.getenv("JWT_ISS")) |s| {
        app_state.jwt_iss = std.mem.span(s);
    }
    if (std.c.getenv("JWT_AUD")) |s| {
        app_state.jwt_aud = std.mem.span(s);
    }
    const use_hsts = std.c.getenv("ENABLE_HSTS") != null;

    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();
    // Keep force_connection_close=true (default). Put nginx/Caddy in front for
    // client keep-alive — see doc/reverse_proxy.md and deploy/{nginx.conf,Caddyfile}.
    app.setConfig(.{
        .port = 8080,
        .force_connection_close = true,
        .drain_timeout_ms = 15_000,
        .request_timeout_ms = 30_000,
        .read_timeout_ms = 30_000,
        .max_body_size = 1 * 1024 * 1024,
    });
    app.setMetrics(&g_metrics);

    try app.get("/health", zfinal.healthHandlerWithChecks(&g_metrics, &.{
        .{ .name = "process", .check = probeProcessAlive },
    }));
    try app.get("/metrics", zfinal.metricsHandlerFor(&g_metrics));

    var token_mgr = zfinal.TokenManager.init(allocator);
    defer token_mgr.deinit();
    token_mgr.setTTL(3600);
    app_state.token_mgr = &token_mgr;
    app.setState(api_handler.AppState, &app_state);

    var rate_limiter = zfinal.RateLimitHandler.init(allocator);
    defer rate_limiter.deinit();
    rate_limiter.max_requests = 60;
    rate_limiter.window_seconds = 60;
    // Behind nginx on loopback only:
    // rate_limiter.trust_proxy_headers = true;
    // rate_limiter.trusted_proxies = &.{"127.0.0.1"};
    g_rate = &rate_limiter;

    var csrf_cfg: zfinal.TokenInterceptorConfig = .{
        .token_manager = &token_mgr,
        .token_name = "_token",
        .error_message = "Invalid or expired CSRF token",
    };
    interceptors.csrf = zfinal.createTokenInterceptor(&csrf_cfg);
    const rate_mw = zfinal.createRateLimitInterceptor(&rate_limiter);
    var jwt_cfg: zfinal.JwtAuthConfig = .{
        .secret = app_state.jwt_secret,
        .opts = .{
            .expected_iss = app_state.jwt_iss,
            .expected_aud = app_state.jwt_aud,
            .previous_secret = app_state.jwt_secret_prev,
            .leeway_sec = 30,
        },
    };
    interceptors.jwt = zfinal.createJwtAuthInterceptorWithOptions(&jwt_cfg);

    try app.addGlobalInterceptor(zfinal.createRequestIdInterceptor());
    var sec_cfg: zfinal.SecurityHeadersConfig = .{ .include_hsts = use_hsts };
    try app.addGlobalInterceptor(zfinal.createSecurityHeadersInterceptor(&sec_cfg));

    // Explicit origins — never ship wildcard CORS for credentialed APIs.
    const cors_origin = blk: {
        if (std.c.getenv("CORS_ORIGIN")) |o| break :blk std.mem.span(o);
        break :blk "http://127.0.0.1:8080";
    };
    // Allow-list: primary origin + optional second via CORS_ORIGIN_2.
    var cors_origins_buf: [2][]const u8 = .{ cors_origin, cors_origin };
    var cors_n: usize = 1;
    if (std.c.getenv("CORS_ORIGIN_2")) |o2| {
        cors_origins_buf[1] = std.mem.span(o2);
        cors_n = 2;
    }
    var cors_cfg: zfinal.CorsAllowlistConfig = .{ .origins = cors_origins_buf[0..cors_n] };
    try app.addGlobalInterceptor(zfinal.createCorsAllowlistInterceptor(&cors_cfg));
    try app.addGlobalInterceptor(rate_mw);

    // L3 demo: MemoryOutbox by default; set ZF_OUTBOX_DB=/path/to.db for durable DbOutbox.
    var bus_impl = zfinal.MemoryBus.init(allocator);
    defer bus_impl.deinit();
    app_state.bus = bus_impl.port();

    var memory_outbox = zfinal.MemoryOutbox.init(allocator);
    defer memory_outbox.deinit();
    var outbox_db: ?*zfinal.DB = null;
    defer if (outbox_db) |d| d.destroy();
    var db_outbox_storage: zfinal.DbOutbox = undefined;

    if (std.c.getenv("ZF_OUTBOX_DB")) |path_z| {
        const path = std.mem.span(path_z);
        outbox_db = try zfinal.DB.init(allocator, zfinal.DBConfig.sqlite(path));
        db_outbox_storage = try zfinal.DbOutbox.init(allocator, outbox_db.?);
        app_state.db_outbox = &db_outbox_storage;
        app_state.outbox = db_outbox_storage.port();
        zfinal.getLogger().infoFmt("Outbox backend: DbOutbox path={s}", .{path});
    } else {
        app_state.memory_outbox = &memory_outbox;
        app_state.outbox = memory_outbox.port();
        zfinal.getLogger().infoFmt("Outbox backend: MemoryOutbox (set ZF_OUTBOX_DB for durable)", .{});
    }

    try api_routes.register(&app);
    try app.postWithInterceptors("/internal/outbox/drain", api_handler.drainOutbox, &.{interceptors.jwt});

    // Optional WS echo with idle timeout (probe via WebSocketManager.tickIdle / Cron).
    try app.addWebSocket("/ws", struct {
        fn echo(ws: *zfinal.WebSocket) !void {
            ws.idle_timeout_ms = 60_000;
            while (true) {
                var frame = ws.receive() catch |err| {
                    if (err == error.ConnectionClosed) break;
                    return err;
                };
                defer frame.deinit();
                if (frame.opcode == .text) try ws.sendText(frame.payload);
            }
        }
    }.echo);

    zfinal.getLogger().infoFmt("Listening on http://0.0.0.0:8080 (drain=15s idle=30s)", .{});
    zfinal.getLogger().infoFmt("Health: /health | Form: /api/form | POST /api/submit | JWT /api/me | WS /ws | drain /internal/outbox/drain", .{});

    try app.start();
}
