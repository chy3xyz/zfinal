//! Production-oriented example: structured logging, auto Metrics,
//! CSRF on POST, rate-limit interceptor, JWT-protected route,
//! restricted CORS, request idle timeout, graceful shutdown.
//!
//! See PRODUCTION_AUDIT.md deployment contract.

const std = @import("std");
const zfinal = @import("zfinal");

pub const log_level = "info";

var g_metrics: zfinal.Metrics = undefined;
var g_token_mgr: *zfinal.TokenManager = undefined;
var g_rate: *zfinal.RateLimitHandler = undefined;
var g_jwt_secret: []const u8 = "change-me-in-production-min-32-bytes!!";

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

    if (std.c.getenv("JWT_SECRET")) |s| {
        g_jwt_secret = std.mem.span(s);
    }

    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();
    app.setConfig(.{
        .port = 8080,
        .drain_timeout_ms = 15_000,
        .request_timeout_ms = 30_000,
        .max_body_size = 1 * 1024 * 1024,
    });
    app.setMetrics(&g_metrics);

    try app.get("/health", zfinal.healthHandlerWithChecks(&g_metrics, &.{
        .{ .name = "process", .check = probeProcessAlive },
    }));

    var token_mgr = zfinal.TokenManager.init(allocator);
    defer token_mgr.deinit();
    token_mgr.setTTL(3600);
    g_token_mgr = &token_mgr;

    var rate_limiter = zfinal.RateLimitHandler.init(allocator);
    defer rate_limiter.deinit();
    rate_limiter.max_requests = 60;
    rate_limiter.window_seconds = 60;
    // Behind nginx on loopback only:
    // rate_limiter.trust_proxy_headers = true;
    // rate_limiter.trusted_proxies = &.{"127.0.0.1"};
    g_rate = &rate_limiter;

    const csrf = zfinal.createTokenInterceptor(.{
        .token_manager = &token_mgr,
        .token_name = "_token",
        .error_message = "Invalid or expired CSRF token",
    });
    const rate_mw = zfinal.createRateLimitInterceptor(&rate_limiter);
    const jwt_mw = zfinal.createJwtAuthInterceptor(g_jwt_secret);

    // Explicit origin — never ship wildcard CORS for credentialed APIs.
    const cors_origin = blk: {
        if (std.c.getenv("CORS_ORIGIN")) |o| break :blk std.mem.span(o);
        break :blk "http://127.0.0.1:8080";
    };
    try app.addGlobalInterceptor(zfinal.createCorsInterceptor(cors_origin));
    try app.addGlobalInterceptor(rate_mw);

    var api = zfinal.RouteGroup.init(&app, "/api");
    _ = try api.get("/form", handleForm);
    try app.postWithInterceptors("/api/submit", handleSubmit, &.{csrf});
    try app.getWithInterceptors("/api/me", handleMe, &.{jwt_mw});
    try app.post("/api/token", handleIssueToken);

    zfinal.getLogger().infoFmt("Listening on http://0.0.0.0:8080 (drain=15s idle=30s)", .{});
    zfinal.getLogger().infoFmt("Health: /health | Form: /api/form | POST /api/submit | JWT /api/me", .{});

    try app.start();
}

fn handleForm(ctx: *zfinal.Context) !void {
    const token = try g_token_mgr.generate();
    defer ctx.allocator.free(token);

    var html_buf: [2048]u8 = undefined;
    const html = try std.fmt.bufPrint(&html_buf,
        \\<html><body>
        \\<h1>ZFinal Production</h1>
        \\<p>Health: /health</p>
        \\<form method="POST" action="/api/submit">
        \\  <input type="hidden" name="_token" value="{s}">
        \\  <input name="message" placeholder="message" required>
        \\  <button type="submit">Submit</button>
        \\</form>
        \\</body></html>
    , .{token});
    try ctx.renderHtml(html);
}

fn handleSubmit(ctx: *zfinal.Context) !void {
    const msg = try ctx.getPara("message") orelse "";
    try ctx.renderJson(.{ .ok = true, .received = msg });
}

fn handleIssueToken(ctx: *zfinal.Context) !void {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const now: i64 = @intCast(ts.sec);
    const token = try zfinal.jwtSign(ctx.allocator, g_jwt_secret, .{
        .sub = "demo-user",
        .exp = now + 3600,
        .iat = now,
        .role = "user",
    });
    defer ctx.allocator.free(token);
    try ctx.renderJson(.{ .token = token, .token_type = "Bearer", .expires_in = 3600 });
}

fn handleMe(ctx: *zfinal.Context) !void {
    const sub = ctx.getAttr("jwt_sub") orelse "unknown";
    const role = ctx.getAttr("jwt_role") orelse "";
    try ctx.renderJson(.{ .sub = sub, .role = role });
}
