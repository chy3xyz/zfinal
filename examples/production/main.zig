//! Production-oriented example: structured logging, Metrics health,
//! CSRF on POST, rate limiting, restricted CORS, graceful shutdown.
//!
//! See PRODUCTION_AUDIT.md deployment contract.

const std = @import("std");
const zfinal = @import("zfinal");

pub const log_level = "info";

var g_metrics: zfinal.Metrics = undefined;
var g_token_mgr: *zfinal.TokenManager = undefined;
var g_rate: *zfinal.RateLimitHandler = undefined;

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

    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();
    app.setConfig(.{
        .port = 8080,
        .drain_timeout_ms = 15_000,
        .max_body_size = 1 * 1024 * 1024,
    });

    try app.get("/health", zfinal.healthHandlerFor(&g_metrics));

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

    // Explicit origin — never ship wildcard CORS for credentialed APIs.
    const cors_origin = blk: {
        if (std.c.getenv("CORS_ORIGIN")) |o| break :blk std.mem.span(o);
        break :blk "http://127.0.0.1:8080";
    };
    try app.addGlobalInterceptor(zfinal.createCorsInterceptor(cors_origin));

    var api = zfinal.RouteGroup.init(&app, "/api");
    _ = try api.get("/form", handleForm);
    try app.postWithInterceptors("/api/submit", handleSubmit, &.{csrf});

    zfinal.getLogger().infoFmt("Listening on http://0.0.0.0:8080 (drain_timeout=15s)", .{});
    zfinal.getLogger().infoFmt("Health: /health | Form: /api/form | POST /api/submit (CSRF)", .{});

    try app.start();
}

fn handleForm(ctx: *zfinal.Context) !void {
    g_rate.handle(ctx) catch {
        g_metrics.recordRequest(429);
        return;
    };
    g_metrics.recordRequest(200);
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
    g_rate.handle(ctx) catch {
        g_metrics.recordRequest(429);
        return;
    };
    g_metrics.recordRequest(200);
    const msg = try ctx.getPara("message") orelse "";
    try ctx.renderJson(.{ .ok = true, .received = msg });
}
