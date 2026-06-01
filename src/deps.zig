const std = @import("std");
const zfinal = @import("zfinal");
pub var pool: ?zfinal.ConnectionPool = null;
pub var tokenMgr: ?zfinal.TokenManager = null;
pub var rateLimiter: ?zfinal.RateLimitHandler = null;

pub fn initDeps(allocator: std.mem.Allocator, db_config: zfinal.DBConfig) !void {
    tokenMgr = zfinal.TokenManager.init(allocator);
    tokenMgr.?.setTTL(3600);
    rateLimiter = zfinal.RateLimitHandler.init(allocator);
    rateLimiter.?.max_requests = 100;
    pool = zfinal.ConnectionPool.init(allocator, db_config, 10);
    _ = pool.?.acquire() catch {};
}

/// Safe accessors — panic with clear message if deps not initialized.
pub fn getPool() *zfinal.ConnectionPool {
    return if (pool) |*p| p else @panic("deps: pool not initialized — call initDeps() first");
}
pub fn getTokenMgr() *zfinal.TokenManager {
    return if (tokenMgr) |*t| t else @panic("deps: tokenMgr not initialized — call initDeps() first");
}
pub fn getRateLimiter() *zfinal.RateLimitHandler {
    return if (rateLimiter) |*r| r else @panic("deps: rateLimiter not initialized — call initDeps() first");
}

pub const corsInterceptor = zfinal.CORSInterceptor;

pub fn healthHandler(ctx: *zfinal.Context) !void {
    try ctx.renderJson(.{ .status = "ok", .uptime = "See /health" });
}
