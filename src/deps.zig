const std = @import("std");
const zfinal = @import("zfinal");
pub var pool: zfinal.ConnectionPool = undefined;
pub var tokenMgr: zfinal.TokenManager = undefined;
pub var rateLimiter: zfinal.RateLimitHandler = undefined;

pub fn initDeps(allocator: std.mem.Allocator) void {{
    tokenMgr = zfinal.TokenManager.init(allocator);
    tokenMgr.setTTL(3600);
    rateLimiter = zfinal.RateLimitHandler.init(allocator);
    rateLimiter.max_requests = 100;
}}
