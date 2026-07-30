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

    interceptors.csrf = zfinal.createTokenInterceptor(.{
        .token_manager = &token_mgr,
        .token_name = "_token",
        .error_message = "Invalid or expired CSRF token",
    });
    const rate_mw = zfinal.createRateLimitInterceptor(&rate_limiter);
    interceptors.jwt = zfinal.createJwtAuthInterceptorWithOptions(app_state.jwt_secret, .{
        .expected_iss = app_state.jwt_iss,
        .expected_aud = app_state.jwt_aud,
        .previous_secret = app_state.jwt_secret_prev,
        .leeway_sec = 30,
    });

    try app.addGlobalInterceptor(zfinal.createRequestIdInterceptor());
    try app.addGlobalInterceptor(zfinal.createSecurityHeadersInterceptor(use_hsts));

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
    try app.addGlobalInterceptor(zfinal.createCorsAllowlistInterceptor(cors_origins_buf[0..cors_n]));
    try app.addGlobalInterceptor(rate_mw);

    try api_routes.register(&app);

    zfinal.getLogger().infoFmt("Listening on http://0.0.0.0:8080 (drain=15s idle=30s)", .{});
    zfinal.getLogger().infoFmt("Health: /health | Form: /api/form | POST /api/submit | JWT /api/me", .{});

    try app.start();
}
