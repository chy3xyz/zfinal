const std = @import("std");
const zfinal = @import("../main.zig");

/// Options for resolving the client IP when a reverse proxy is present.
pub const ClientIpOptions = struct {
    /// When false (default), proxy headers are ignored — clients cannot spoof IPs.
    trust_proxy_headers: bool = false,
    /// If non-empty, proxy headers are only trusted when the peer socket address
    /// (formatted) matches one of these entries exactly (e.g. "127.0.0.1:443").
    /// When empty and trust_proxy_headers is true, any peer may supply headers
    /// (private-network convenience; document the risk).
    trusted_proxies: []const []const u8 = &.{},
};

/// IP 工具扩展
pub const IpExt = struct {
    /// Peer IP address of a connected socket, or null when the family is
    /// unsupported or the syscall fails. Fills the long-standing gap where
    /// `Context.remote_addr` was declared but never populated by the server.
    pub fn peerIpAddress(handle: std.posix.socket_t) ?std.Io.net.IpAddress {
        var storage: std.posix.sockaddr.storage = undefined;
        var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
        std.posix.getpeername(handle, @ptrCast(&storage), &len) catch return null;
        const sa: *const std.posix.sockaddr = @ptrCast(&storage);
        return switch (sa.family) {
            std.posix.AF.INET => blk: {
                const sin: *const std.posix.sockaddr.in = @ptrCast(@alignCast(sa));
                // sin.addr is in_addr.s_addr in network byte order; @bitCast
                // takes the in-memory octets directly (127.0.0.1 → {127,0,0,1}).
                // Do NOT bigToNative here — it would byte-swap on LE hosts.
                break :blk std.Io.net.IpAddress{ .ip4 = .{
                    .bytes = @bitCast(sin.addr),
                    .port = std.mem.bigToNative(u16, sin.port),
                } };
            },
            std.posix.AF.INET6 => blk: {
                const sin6: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(sa));
                break :blk std.Io.net.IpAddress{ .ip6 = .{
                    .port = std.mem.bigToNative(u16, sin6.port),
                    .bytes = sin6.addr,
                } };
            },
            else => null,
        };
    }

    /// Format an IpAddress as a dotted-quad / colon-hex string ("127.0.0.1").
    /// `buf` must outlive the return (must be ≥ INET6_ADDRSTRLEN-ish; 64 is fine).
    /// Unlike `"{}"` (which prints the Debug struct), this produces a string
    /// comparable against `trusted_proxies` allow-lists.
    pub fn formatIpAddress(addr: std.Io.net.IpAddress, buf: []u8) []const u8 {
        return switch (addr) {
            .ip4 => |a| std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }) catch return "?",
            .ip6 => |a| {
                // 8 groups of 4 hex digits, colon-separated (no compression).
                var out: [std.fmt.count("{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{ @as(u16, 0), @as(u16, 0), @as(u16, 0), @as(u16, 0), @as(u16, 0), @as(u16, 0), @as(u16, 0), @as(u16, 0) })]u8 = undefined;
                const s = std.fmt.bufPrint(&out, "{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{
                    (@as(u16, a.bytes[0]) << 8) | a.bytes[1],
                    (@as(u16, a.bytes[2]) << 8) | a.bytes[3],
                    (@as(u16, a.bytes[4]) << 8) | a.bytes[5],
                    (@as(u16, a.bytes[6]) << 8) | a.bytes[7],
                    (@as(u16, a.bytes[8]) << 8) | a.bytes[9],
                    (@as(u16, a.bytes[10]) << 8) | a.bytes[11],
                    (@as(u16, a.bytes[12]) << 8) | a.bytes[13],
                    (@as(u16, a.bytes[14]) << 8) | a.bytes[15],
                }) catch return "?";
                if (s.len > buf.len) return "?";
                @memcpy(buf[0..s.len], s);
                return buf[0..s.len];
            },
        };
    }

    /// Secure default: never trust client-controlled proxy headers.
    /// Prefer `resolveClientIp` with an explicit `ClientIpOptions` behind a reverse proxy.
    pub fn getRealIp(ctx: *zfinal.Context) []const u8 {
        var buf: [64]u8 = undefined;
        return resolveClientIp(ctx, &buf, .{}) catch "unknown";
    }

    /// Resolve client IP with explicit proxy trust policy.
    /// `buf` is used to format `ctx.remote_addr` when present (must outlive the return).
    pub fn resolveClientIp(ctx: *zfinal.Context, buf: []u8, opts: ClientIpOptions) ![]const u8 {
        const remote_str: ?[]const u8 = if (ctx.remote_addr) |addr|
            formatIpAddress(addr, buf)
        else
            null;

        if (opts.trust_proxy_headers) {
            const peer_trusted = if (opts.trusted_proxies.len == 0)
                true
            else if (remote_str) |r|
                isTrustedProxy(r, opts.trusted_proxies)
            else
                false;

            if (peer_trusted) {
                if (ctx.getHeader("X-Real-IP")) |ip| return ip;
                if (ctx.getHeader("X-Forwarded-For")) |forwarded| {
                    if (std.mem.indexOf(u8, forwarded, ",")) |comma_pos| {
                        return std.mem.trim(u8, forwarded[0..comma_pos], &std.ascii.whitespace);
                    }
                    return forwarded;
                }
            }
        }

        return remote_str orelse "unknown";
    }

    pub fn isTrustedProxy(remote: []const u8, proxies: []const []const u8) bool {
        for (proxies) |p| {
            if (std.mem.eql(u8, remote, p)) return true;
            // Also allow matching host without port: "127.0.0.1" vs "127.0.0.1:1234"
            if (std.mem.indexOfScalar(u8, remote, ':')) |colon| {
                if (std.mem.eql(u8, remote[0..colon], p)) return true;
            }
        }
        return false;
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

test "IpExt: proxy headers ignored by default" {
    // Pure unit of isTrustedProxy + policy: without trust, headers must not win.
    try std.testing.expect(!IpExt.isTrustedProxy("10.0.0.1:80", &.{}));
    try std.testing.expect(IpExt.isTrustedProxy("10.0.0.1:80", &.{"10.0.0.1"}));
    try std.testing.expect(IpExt.isTrustedProxy("10.0.0.1:80", &.{"10.0.0.1:80"}));
    try std.testing.expect(!IpExt.isTrustedProxy("10.0.0.2:80", &.{"10.0.0.1"}));
}

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
        return try zfinal.HashKit.generateRandomString(allocator, 32);
    }

    /// 验证 CSRF Token
    pub fn validateCsrfToken(ctx: *zfinal.Context, token: []const u8) bool {
        const session_token = ctx.getSessionAttr("_csrf_token") orelse return false;
        return std.mem.eql(u8, token, session_token);
    }
};

test "IpExt.formatIpAddress renders dotted-quad / hex string" {
    var buf: [64]u8 = undefined;
    const ip4 = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
    try std.testing.expectEqualStrings("127.0.0.1", IpExt.formatIpAddress(ip4, &buf));
    const ip6 = std.Io.net.IpAddress{ .ip6 = .{ .port = 0, .bytes = .{ 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8 } } };
    try std.testing.expectEqualStrings("1:2:3:4:5:6:7:8", IpExt.formatIpAddress(ip6, &buf));
}

test "IpExt.resolveClientIp trusts proxy only when peer matches allow-list" {
    const a = std.testing.allocator;
    var ctx: zfinal.Context = undefined;
    ctx.allocator = a;
    ctx.remote_addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 54321 } };
    ctx.mock_headers = std.StringHashMap([]const u8).init(a);
    defer ctx.mock_headers.?.deinit();
    try ctx.mock_headers.?.put("x-real-ip", "203.0.113.9");
    try ctx.mock_headers.?.put("x-forwarded-for", "198.51.100.4");

    var buf: [64]u8 = undefined;
    // trusted peer (127.0.0.1 in allow-list) → proxy headers win.
    const trusted = try IpExt.resolveClientIp(&ctx, &buf, .{
        .trust_proxy_headers = true,
        .trusted_proxies = &.{"127.0.0.1"},
    });
    try std.testing.expectEqualStrings("203.0.113.9", trusted); // X-Real-IP preferred

    // untrusted peer (allow-list excludes us) → real socket address wins.
    ctx.remote_addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 10, 0, 0, 5 }, .port = 54321 } };
    const untrusted = try IpExt.resolveClientIp(&ctx, &buf, .{
        .trust_proxy_headers = true,
        .trusted_proxies = &.{"127.0.0.1"},
    });
    try std.testing.expectEqualStrings("10.0.0.5", untrusted);
}
