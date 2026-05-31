const std = @import("std");
const zfinal = @import("zfinal");

pub fn main(init: std.process.Init) !void {
    zfinal.io_instance.init(init);
    const allocator = init.gpa;

    // Init MySQL pool (required by generated handlers)
    const db_cfg = zfinal.DBConfig.mysql("ruoyi_vue_pro", "root", "");
    var pool = zfinal.ConnectionPool.init(allocator, db_cfg, 8);
    defer pool.deinit();

    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();

    try app.get("/api/ping", struct {
        fn h(ctx: *zfinal.Context) anyerror!void {
            try ctx.renderJson(.{ .ok = true });
        }
    }.h);

    // Set up deps module — handlers need this
    const deps = @import("src/deps.zig");
    deps.pool = pool;
    deps.tokenMgr = zfinal.TokenManager.init(allocator);
    deps.tokenMgr.setTTL(3600);
    deps.rateLimiter = zfinal.RateLimitHandler.init(allocator);

    try @import("src/modules/manifest.gen.zig").registerAll(&app);
    app.config = .{ .port = 8084 };
    try app.start();
}
