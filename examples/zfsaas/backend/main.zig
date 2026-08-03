//! zfsaas backend — org-scoped SaaS API (auth / org / billing / todo).
//!
//!   zig build run-zfsaas
//!
//! Env: JWT_SECRET, SAAS_DB, STRIPE_*, PUBLIC_BASE_URL, CORS_ORIGIN
const std = @import("std");
const zfinal = @import("zfinal");

const state_mod = @import("src/state.zig");
const migrate = @import("src/migrate.zig");
const interceptors = @import("src/interceptors.zig");
const task_runner = @import("src/task_runner.zig");
const auth_handler = @import("src/modules/auth/handler.zig");
const org_handler = @import("src/modules/org/handler.zig");
const billing_handler = @import("src/modules/billing/handler.zig");
const todo_routes = @import("src/modules/todo/routes.zig");

/// File-scope so `healthHandlerWithChecks(&g_metrics, ...)` can take a comptime pointer.
var g_metrics: zfinal.Metrics = undefined;

pub fn main(init: std.process.Init) !void {
    zfinal.io_instance.init(init);
    const allocator = init.gpa;

    var jwt_secret: []const u8 = "saas-kit-dev-secret-change-me-32b!!";
    if (std.c.getenv("JWT_SECRET")) |s| jwt_secret = std.mem.span(s);

    const db_path: []const u8 = if (std.c.getenv("SAAS_DB")) |p| std.mem.span(p) else "saas-kit.db";
    var db = try zfinal.DB.init(allocator, zfinal.DBConfig.sqlite(db_path));
    defer db.destroy();
    try migrate.migrate(db);

    var app_state: state_mod.AppState = .{
        .db = db,
        .allocator = allocator,
        .jwt_secret = jwt_secret,
    };
    if (std.c.getenv("STRIPE_SECRET")) |s| app_state.stripe_secret = std.mem.span(s);
    if (std.c.getenv("STRIPE_WEBHOOK_SECRET")) |s| app_state.stripe_webhook_secret = std.mem.span(s);
    if (std.c.getenv("STRIPE_PRICE_ID")) |s| app_state.stripe_price_id = std.mem.span(s);
    if (std.c.getenv("PUBLIC_BASE_URL")) |s| app_state.public_base_url = std.mem.span(s);

    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();
    app.setConfig(.{
        .port = 8080,
        .force_connection_close = true,
        .max_body_size = 1 * 1024 * 1024,
    });
    app.setState(state_mod.AppState, &app_state);

    // P0: metrics + health probes
    g_metrics = zfinal.Metrics.init(allocator);
    defer g_metrics.deinit();
    app.setMetrics(&g_metrics);

    // P0: global per-IP rate limiter (300 req/min)
    interceptors.rate_limiter = zfinal.RateLimitHandler.init(allocator);
    interceptors.rate_limiter.max_requests = 300;

    // P0: background tasks (subscription expiry, invite cleanup)
    try task_runner.register(allocator, .{ .name = "subscription_expiry", .interval_sec = 60, .run = task_runner.expireSubscriptions });
    try task_runner.register(allocator, .{ .name = "invite_cleanup", .interval_sec = 3600, .run = task_runner.cleanupInvites });
    try task_runner.start(db, allocator);

    interceptors.jwt_cfg = .{
        .secret = jwt_secret,
        .opts = .{
            .expected_iss = "zfinal-saas-kit",
            .leeway_sec = 30,
        },
    };
    const jwt_mw = interceptors.createJwtInterceptor(&interceptors.jwt_cfg);
    const org_mw = interceptors.orgMemberInterceptor;
    const protected = [_]zfinal.Interceptor{ jwt_mw, org_mw };
    const auth_only = [_]zfinal.Interceptor{jwt_mw};

    try app.addGlobalInterceptor(zfinal.createRequestIdInterceptor());
    try app.addGlobalInterceptor(interceptors.createRateLimitInterceptor());

    // Allow SolidStart frontend (default :3000). Buffer must outlive app.start.
    const cors_origin = blk: {
        if (std.c.getenv("CORS_ORIGIN")) |o| break :blk std.mem.span(o);
        break :blk "http://localhost:3000";
    };
    var cors_origins_buf = [_][]const u8{cors_origin};
    var cors_cfg: zfinal.CorsAllowlistConfig = .{ .origins = cors_origins_buf[0..] };
    try app.addGlobalInterceptor(zfinal.createCorsAllowlistInterceptor(&cors_cfg));

    try app.get("/health", zfinal.healthHandlerWithChecks(&g_metrics, &.{}));
    try app.get("/metrics", zfinal.metricsHandlerFor(&g_metrics));
    try app.get("/api/health", health);

    try app.post("/api/auth/sign-up", auth_handler.signUp);
    try app.post("/api/auth/sign-in", auth_handler.signIn);
    try app.post("/api/auth/refresh", auth_handler.refresh);
    try app.post("/api/auth/revoke", auth_handler.revoke);
    try app.post("/api/auth/verify-email", auth_handler.verifyEmail);
    try app.post("/api/auth/password-reset/request", auth_handler.requestReset);
    try app.post("/api/auth/password-reset/confirm", auth_handler.confirmReset);
    try app.getWithInterceptors("/api/auth/me", auth_handler.me, &auth_only);

    try app.getWithInterceptors("/api/orgs", org_handler.list, &auth_only);
    try app.postWithInterceptors("/api/orgs", org_handler.create, &auth_only);
    try app.postWithInterceptors("/api/orgs/switch", org_handler.switchOrg, &auth_only);
    try app.postWithInterceptors("/api/orgs/:id/invites", org_handler.invite, &protected);
    try app.postWithInterceptors("/api/invites/accept", org_handler.acceptInvite, &auth_only);

    try app.getWithInterceptors("/api/billing/subscription", billing_handler.subscription, &protected);
    try app.postWithInterceptors("/api/billing/checkout", billing_handler.checkout, &protected);
    try app.post("/api/billing/webhook", billing_handler.webhook);

    try todo_routes.register(&app, &protected);

    std.debug.print("zfsaas backend on :8080 (db={s}) cors={s}\n", .{ db_path, cors_origin });
    std.debug.print("  POST /api/auth/sign-up | /api/auth/sign-in\n", .{});
    std.debug.print("  GET  /api/orgs | POST /api/billing/checkout (mock without STRIPE_SECRET)\n", .{});
    std.debug.print("  CRUD /api/todos (requires active subscription for writes)\n", .{});
    try app.start();
}

fn health(ctx: *zfinal.Context) !void {
    try ctx.renderJson(.{ .ok = true, .data = .{ .status = "ok", .service = "zfsaas" }, .@"error" = null });
}
