const std = @import("std");
const zfinal = @import("../main.zig");

/// IP 工具扩展
pub const IpExt = struct {
    /// 获取客户端真实 IP
    pub fn getRealIp(ctx: *zfinal.Context) []const u8 {
        // 优先级: X-Real-IP > X-Forwarded-For > Remote-Addr
        if (ctx.getHeader("X-Real-IP")) |ip| {
            return ip;
        }

        if (ctx.getHeader("X-Forwarded-For")) |forwarded| {
            // X-Forwarded-For 可能包含多个 IP，取第一个
            if (std.mem.indexOf(u8, forwarded, ",")) |comma_pos| {
                return std.mem.trim(u8, forwarded[0..comma_pos], &std.ascii.whitespace);
            }
            return forwarded;
        }

        return "unknown";
    }

    /// 检查是否是本地 IP
    pub fn isLocalIp(ip: []const u8) bool {
        return std.mem.startsWith(u8, ip, "127.") or
            std.mem.startsWith(u8, ip, "192.168.") or
            std.mem.startsWith(u8, ip, "10.") or
            std.mem.eql(u8, ip, "localhost") or
            std.mem.eql(u8, ip, "::1");
    }
};

/// 请求工具扩展
pub const RequestExt = struct {
    /// 检查是否是 AJAX 请求
    pub fn isAjax(ctx: *zfinal.Context) bool {
        if (ctx.getHeader("X-Requested-With")) |value| {
            return std.mem.eql(u8, value, "XMLHttpRequest");
        }
        return false;
    }

    /// 检查是否是移动端
    pub fn isMobile(ctx: *zfinal.Context) bool {
        const ua = ctx.getHeader("User-Agent") orelse return false;
        return std.mem.indexOf(u8, ua, "Mobile") != null or
            std.mem.indexOf(u8, ua, "Android") != null or
            std.mem.indexOf(u8, ua, "iPhone") != null;
    }

    /// 获取请求方法
    pub fn getMethod(ctx: *zfinal.Context) []const u8 {
        return @tagName(ctx.req.head.method);
    }

    /// 检查是否是指定方法
    pub fn isMethod(ctx: *zfinal.Context, method: []const u8) bool {
        return std.mem.eql(u8, getMethod(ctx), method);
    }
};

/// 响应工具扩展
pub const ResponseExt = struct {
    /// 设置 JSON 响应头
    pub fn setJsonHeader(ctx: *zfinal.Context) !void {
        try ctx.setHeader("Content-Type", "application/json; charset=utf-8");
    }

    /// 设置下载响应头
    pub fn setDownloadHeader(ctx: *zfinal.Context, filename: []const u8) !void {
        var buf: [512]u8 = undefined;
        const disposition = try std.fmt.bufPrint(&buf, "attachment; filename=\"{s}\"", .{filename});
        try ctx.setHeader("Content-Disposition", disposition);
    }

    /// 设置缓存头
    pub fn setCacheHeader(ctx: *zfinal.Context, max_age: i64) !void {
        var buf: [64]u8 = undefined;
        const cache_control = try std.fmt.bufPrint(&buf, "max-age={d}", .{max_age});
        try ctx.setHeader("Cache-Control", cache_control);
    }

    /// 设置不缓存
    pub fn setNoCache(ctx: *zfinal.Context) !void {
        try ctx.setHeader("Cache-Control", "no-cache, no-store, must-revalidate");
        try ctx.setHeader("Pragma", "no-cache");
        try ctx.setHeader("Expires", "0");
    }
};

/// Cookie 工具扩展
pub const CookieExt = struct {
    /// 设置 Cookie（带过期时间）
    pub fn set(ctx: *zfinal.Context, name: []const u8, value: []const u8, max_age: i64) !void {
        var buf: [1024]u8 = undefined;
        const cookie = try std.fmt.bufPrint(&buf, "{s}={s}; Max-Age={d}; Path=/; HttpOnly", .{ name, value, max_age });
        try ctx.setHeader("Set-Cookie", cookie);
    }

    /// 设置安全 Cookie（HTTPS only）
    pub fn setSecure(ctx: *zfinal.Context, name: []const u8, value: []const u8, max_age: i64) !void {
        var buf: [1024]u8 = undefined;
        const cookie = try std.fmt.bufPrint(&buf, "{s}={s}; Max-Age={d}; Path=/; HttpOnly; Secure; SameSite=Strict", .{ name, value, max_age });
        try ctx.setHeader("Set-Cookie", cookie);
    }

    /// 删除 Cookie
    pub fn remove(ctx: *zfinal.Context, name: []const u8) !void {
        var buf: [512]u8 = undefined;
        const cookie = try std.fmt.bufPrint(&buf, "{s}=; Max-Age=0; Path=/", .{name});
        try ctx.setHeader("Set-Cookie", cookie);
    }
};

/// 安全工具扩展
pub const SecurityExt = struct {
    /// 设置安全响应头
    pub fn setSecurityHeaders(ctx: *zfinal.Context) !void {
        try ctx.setHeader("X-Content-Type-Options", "nosniff");
        try ctx.setHeader("X-Frame-Options", "DENY");
        try ctx.setHeader("X-XSS-Protection", "1; mode=block");
        try ctx.setHeader("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
    }

    /// 生成 CSRF Token
    pub fn generateCsrfToken(allocator: std.mem.Allocator) ![]const u8 {
        return try zfinal.RandomKit.generateRandomString(allocator, 32);
    }

    /// 验证 CSRF Token
    pub fn validateCsrfToken(ctx: *zfinal.Context, token: []const u8) bool {
        const session_token = ctx.getSessionAttr("_csrf_token") orelse return false;
        return std.mem.eql(u8, token, session_token);
    }
};
