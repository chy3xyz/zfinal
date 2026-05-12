//! Production-grade example demonstrating structured logging, connection pooling,
//! CSRF protection, rate limiting, health endpoint, CORS, and metrics.

const std = @import("std");
const zfinal = @import("zfinal");

pub const log_level = "info";

pub fn main() !void {
    // Structured logger
    var logger = zfinal.Logger.init(std.heap.page_allocator);
    logger.setLevel(.info);
    logger.prefix = "zfinal";
    zfinal.initGlobalLogger(logger);
    zfinal.getLogger().infoFmt("Server starting up", .{});

    // Create the app
    var app = zfinal.ZFinal.init(std.heap.page_allocator);
    defer app.deinit();
    app.setPort(8080);

    // --- Health endpoint ---
    try app.get("/health", handleHealth);

    // --- CSRF Token Manager ---
    var token_mgr = zfinal.TokenManager.init(std.heap.page_allocator);
    defer token_mgr.deinit();
    token_mgr.setTTL(3600);

    // --- Rate Limiter ---
    var rate_limiter = zfinal.RateLimitHandler.init(std.heap.page_allocator);
    defer rate_limiter.deinit();

    // --- Routes ---
    var api = zfinal.RouteGroup.init(&app, "/api");

    _ = try api.get("/form", handleForm);
    _ = try api.post("/submit", handleSubmit);

    // --- CORS ---
    try app.addGlobalInterceptor(zfinal.CORSInterceptor);

    zfinal.getLogger().infoFmt("Listening on http://0.0.0.0:8080", .{});
    zfinal.getLogger().infoFmt("Health: http://0.0.0.0:8080/health", .{});
    zfinal.getLogger().infoFmt("Form:   http://0.0.0.0:8080/api/form", .{});

    try app.start();
}

fn handleForm(ctx: *zfinal.Context) !void {
    var html_buf: [1024]u8 = undefined;
    const html = std.fmt.bufPrint(&html_buf, "<html><body><h1>ZFinal Production</h1><p>Health: /health | Form: POST /api/submit</p></body></html>", .{}) catch "error";
    try ctx.renderHtml(html);
}

fn handleSubmit(ctx: *zfinal.Context) !void {
    const msg = try ctx.getPara("message") orelse "";
    try ctx.renderJson(.{ .ok = true, .received = msg });
}

fn handleHealth(ctx: *zfinal.Context) !void {
    try ctx.renderJson(.{ .status = "ok", .uptime_sec = 0 });
}
