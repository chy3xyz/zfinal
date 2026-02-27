const std = @import("std");
const zfinal = @import("../main.zig");

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

        // 构建文件路径
        var file_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&file_path_buf, "{s}{s}", .{ self.root_path, path });

        // 读取文件
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
    mutex: std.Thread.Mutex = .{},
    max_requests: usize = 100,
    window_seconds: i64 = 60,

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
        const client_ip = ctx.getHeader("X-Real-IP") orelse ctx.getHeader("X-Forwarded-For") orelse "unknown";

        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();

        if (self.requests.getPtr(client_ip)) |info| {
            // 检查是否在同一时间窗口
            if (now - info.window_start < self.window_seconds) {
                if (info.count >= self.max_requests) {
                    ctx.res_status = .too_many_requests;
                    try ctx.renderJson(.{ .err = "Too many requests" });
                    return error.TooManyRequests;
                }
                info.count += 1;
            } else {
                // 新的时间窗口
                info.count = 1;
                info.window_start = now;
            }
        } else {
            // 新客户端
            const ip_copy = try self.allocator.dupe(u8, client_ip);
            try self.requests.put(ip_copy, RequestInfo{
                .count = 1,
                .window_start = now,
            });
        }
    }
};
