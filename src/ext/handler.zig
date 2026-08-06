const std = @import("std");
const io_instance = @import("../io_instance.zig");
const zfinal = @import("../main.zig");
const mutex_init = @import("../db/mutex_init.zig");
const IpExt = @import("ext_util.zig").IpExt;

/// CORS Handler - 跨域资源共享
pub const CorsHandler = struct {
    allowed_origins: []const []const u8,
    allowed_methods: []const u8 = "GET,POST,PUT,DELETE,OPTIONS",
    allowed_headers: []const u8 = "Content-Type,Authorization",
    max_age: i64 = 86400, // 24 hours

    pub fn handle(self: *const CorsHandler, ctx: *zfinal.Context) !void {
        const origin = ctx.getHeader("Origin");

        if (origin) |o| {
            // 检查是否允许该来源
            var allowed = false;
            for (self.allowed_origins) |allowed_origin| {
                if (std.mem.eql(u8, allowed_origin, "*") or std.mem.eql(u8, allowed_origin, o)) {
                    allowed = true;
                    break;
                }
            }

            if (allowed) {
                try ctx.setHeader("Access-Control-Allow-Origin", o);
                try ctx.setHeader("Access-Control-Allow-Methods", self.allowed_methods);
                try ctx.setHeader("Access-Control-Allow-Headers", self.allowed_headers);

                var max_age_buf: [32]u8 = undefined;
                const max_age_str = try std.fmt.bufPrint(&max_age_buf, "{d}", .{self.max_age});
                try ctx.setHeader("Access-Control-Max-Age", max_age_str);
            }
        }

        // OPTIONS 请求直接返回
        if (std.mem.eql(u8, @tagName(ctx.req.head.method), "OPTIONS")) {
            ctx.res_status = .no_content;
            return;
        }
    }
};

/// 静态资源 Handler
pub const StaticHandler = struct {
    root_path: []const u8,
    cache_seconds: i64 = 3600,

    pub fn handle(self: *const StaticHandler, ctx: *zfinal.Context) !void {
        const path = ctx.req.head.target;

        // 安全路径校验：拒绝路径遍历攻击
        if (std.mem.indexOf(u8, path, "..") != null) {
            ctx.res_status = .forbidden;
            try ctx.renderText("403 Forbidden");
            return;
        }

        // 构建文件路径并规范化
        var file_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&file_path_buf, "{s}{s}", .{ self.root_path, path });

        // 双重校验：确保解析后的路径仍在 root_path 下
        const resolved = std.fs.cwd().realpath(file_path, &file_path_buf) catch |err| {
            if (err == error.FileNotFound) {
                ctx.res_status = .not_found;
                try ctx.renderText("404 Not Found");
                return;
            }
            return err;
        };
        if (!std.mem.startsWith(u8, resolved, self.root_path)) {
            ctx.res_status = .forbidden;
            try ctx.renderText("403 Forbidden");
            return;
        }

        // 读取文件（限制 10MB）
        const content = std.fs.cwd().readFileAlloc(ctx.allocator, file_path, 10 * 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) {
                ctx.res_status = .not_found;
                try ctx.renderText("404 Not Found");
                return;
            }
            return err;
        };
        defer ctx.allocator.free(content);

        // 设置缓存头
        if (self.cache_seconds > 0) {
            var cache_buf: [64]u8 = undefined;
            const cache_control = try std.fmt.bufPrint(&cache_buf, "max-age={d}", .{self.cache_seconds});
            try ctx.setHeader("Cache-Control", cache_control);
        }

        // 设置 Content-Type
        if (zfinal.PathKit.getExt(file_path)) |ext| {
            const mime_type = zfinal.HttpKit.getMimeType(ext);
            try ctx.setHeader("Content-Type", mime_type);
        }

        try ctx.renderText(content);
    }
};

/// 请求限流 Handler
pub const RateLimitHandler = struct {
    requests: std.StringHashMap(RequestInfo),
    allocator: std.mem.Allocator,
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    max_requests: usize = 100,
    window_seconds: i64 = 60,
    /// Set to true when behind a trusted reverse proxy (nginx, haproxy).
    /// Default false: clients cannot spoof rate-limit keys via X-Forwarded-For.
    trust_proxy_headers: bool = false,
    /// Optional allow-list of peer addresses that may supply proxy headers.
    /// Empty + trust_proxy_headers=true means trust any peer (private networks only).
    trusted_proxies: []const []const u8 = &.{},
    /// Controls how often stale entries are cleaned up (every N handle() calls).
    cleanup_counter: usize = 0,
    cleanup_interval: usize = 1000,
    /// When true, over-limit requests get a 429 response written directly
    /// (instead of `error.TooManyRequests`). Default false keeps the error
    /// semantics so callers control the response contract.
    render_429: bool = false,

    const RequestInfo = struct {
        count: usize,
        window_start: i64,
    };

    pub fn init(allocator: std.mem.Allocator) RateLimitHandler {
        return RateLimitHandler{
            .requests = std.StringHashMap(RequestInfo).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RateLimitHandler) void {
        var it = self.requests.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.requests.deinit();
    }

    pub fn handle(self: *RateLimitHandler, ctx: *zfinal.Context) !void {
        var key_buf: [64]u8 = undefined;
        const client_key = try IpExt.resolveClientIp(ctx, &key_buf, .{
            .trust_proxy_headers = self.trust_proxy_headers,
            .trusted_proxies = self.trusted_proxies,
        });

        mutex_init.lockMut(&self.mutex);
        defer mutex_init.unlockMut(&self.mutex);

        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        const now: i64 = @intCast(ts.sec);

        // Periodic cleanup of stale entries
        self.cleanup_counter += 1;
        if (self.cleanup_counter >= self.cleanup_interval) {
            self.cleanup_counter = 0;
            self.cleanupStale(now);
        }

        if (self.requests.getPtr(client_key)) |info| {
            if (now - info.window_start < self.window_seconds) {
                if (info.count >= self.max_requests) {
                    if (self.render_429) {
                        // Opt-in: write a 429 body instead of raising, so the
                        // error contract is the caller's choice. Keeps the
                        // default error semantics (catch + render yourself).
                        ctx.res_status = .too_many_requests;
                        try ctx.renderText("429 Too Many Requests");
                        return;
                    }
                    return error.TooManyRequests;
                }
                info.count += 1;
            } else {
                info.count = 1;
                info.window_start = now;
            }
        } else {
            const key_copy = try self.allocator.dupe(u8, client_key);
            try self.requests.put(key_copy, RequestInfo{
                .count = 1,
                .window_start = now,
            });
        }
    }

    fn cleanupStale(self: *RateLimitHandler, now: i64) void {
        const cutoff = now - self.window_seconds * 2;
        var to_remove = std.ArrayList([]const u8).empty;
        defer to_remove.deinit(self.allocator);

        var it = self.requests.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.window_start < cutoff) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }

        for (to_remove.items) |key| {
            if (self.requests.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
            }
        }
    }
};

test "RateLimitHandler enforces window (peer key from remote_addr)" {
    const a = std.testing.allocator;
    var rl = RateLimitHandler.init(a);
    rl.max_requests = 2;
    rl.window_seconds = 60;
    defer rl.deinit();

    var ctx: zfinal.Context = undefined;
    ctx.allocator = a;
    ctx.remote_addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 1 } };

    try rl.handle(&ctx);
    try rl.handle(&ctx);
    try std.testing.expectError(error.TooManyRequests, rl.handle(&ctx));
}
