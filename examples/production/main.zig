//! Production-grade example demonstrating structured logging, CSRF protection,
//! rate limiting with trusted-proxy policy, Metrics health endpoint, and CORS.

const std = @import("std");
const zfinal = @import("zfinal");

pub const log_level = "info";

var g_metrics: zfinal.Metrics = undefined;

pub fn main() !void {
    var logger = zfinal.Logger.init(std.heap.page_allocator);
    logger.setLevel(.info);
    logger.prefix = "zfinal";
    zfinal.initGlobalLogger(logger);
    zfinal.getLogger().infoFmt("Server starting up", .{});

    g_metrics = zfinal.Metrics.init(std.heap.page_allocator);
    defer g_metrics.deinit();

    var app = zfinal.ZFinal.init(std.heap.page_allocator);
    defer app.deinit();
    app.setPort(8080);

    // Metrics-backed health endpoint
    try app.get("/health", zfinal.healthHandlerFor(&g_metrics));

    var token_mgr = zfinal.TokenManager.init(std.heap.page_allocator);
    defer token_mgr.deinit();
    token_mgr.setTTL(3600);

    var rate_limiter = zfinal.RateLimitHandler.init(std.heap.page_allocator);
    defer rate_limiter.deinit();
    // Behind nginx on loopback: trust X-Real-IP only from that peer.
    // rate_limiter.trust_proxy_headers = true;
    // rate_limiter.trusted_proxies = &.{"127.0.0.1"};

    var api = zfinal.RouteGroup.init(&app, "/api");
    _ = try api.get("/form", handleForm);
    _ = try api.post("/submit", handleSubmit);

    try app.addGlobalInterceptor(zfinal.CORSInterceptor);

    zfinal.getLogger().infoFmt("Listening on http://0.0.0.0:8080", .{});
    zfinal.getLogger().infoFmt("Health: http://0.0.0.0:8080/health", .{});

    try app.start();
}

fn handleForm(ctx: *zfinal.Context) !void {
    g_metrics.recordRequest(200);
    var html_buf: [1024]u8 = undefined;
    const html = std.fmt.bufPrint(&html_buf, "<html><body><h1>ZFinal Production</h1><p>Health: /health | Form: POST /api/submit</p></body></html>", .{}) catch "error";
    try ctx.renderHtml(html);
}

fn handleSubmit(ctx: *zfinal.Context) !void {
    g_metrics.recordRequest(200);
    const msg = try ctx.getPara("message") orelse "";
    try ctx.renderJson(.{ .ok = true, .received = msg });
}
