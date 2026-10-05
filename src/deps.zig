const std = @import("std");
const zfinal = @import("zfinal");
pub var pool: *zfinal.ConnectionPool = undefined;
pub var tokenMgr: zfinal.TokenManager = undefined;
pub var rateLimiter: zfinal.RateLimitHandler = undefined;

pub fn initDeps(allocator: std.mem.Allocator, db_config: zfinal.DBConfig) !void {
    tokenMgr = zfinal.TokenManager.init(allocator);
    tokenMgr.setTTL(3600);
    rateLimiter = zfinal.RateLimitHandler.init(allocator);
    rateLimiter.max_requests = 100;
    pool = try zfinal.ConnectionPool.init(allocator, db_config, 10);
    // Warm-up acquire must be returned, otherwise one of the 10 slots is lost
    // forever (the connection stays marked checked-out).
    if (pool.acquire()) |conn| {
        pool.release(conn) catch {};
    } else |_| {}
}

pub const corsInterceptor = zfinal.CORSInterceptor;

pub fn healthHandler(ctx: *zfinal.Context) !void {
    try ctx.renderJson(.{ .status = "ok", .uptime = "See /health" });
}

pub fn getPool() *zfinal.ConnectionPool {
    return pool;
}

pub fn getTokenMgr() *zfinal.TokenManager {
    return &tokenMgr;
}

pub fn getRateLimiter() *zfinal.RateLimitHandler {
    return &rateLimiter;
}
