const std = @import("std");
const zfinal = @import("../main.zig");
const TimeKit = @import("../kit/time_kit.zig").TimeKit;
const IpExt = @import("ext_util.zig").IpExt;

/// 性能监控拦截器
pub fn createPerformanceInterceptor() zfinal.Interceptor {
    const Impl = struct {
        fn before(ctx: *zfinal.Context, _: ?*anyopaque) !bool {
            const start_time = TimeKit.nowMillis();
            var buf: [32]u8 = undefined;
            const start_str = try std.fmt.bufPrint(&buf, "{d}", .{start_time});
            try ctx.setAttr("_start_time", start_str);
            return true;
        }

        fn after(ctx: *zfinal.Context, _: ?*anyopaque) !void {
            // getAttr returns a map-owned borrow — do not free.
            if (ctx.getAttr("_start_time")) |start_str| {
                const start_time = try std.fmt.parseInt(i64, start_str, 10);
                const end_time = TimeKit.nowMillis();
                const duration = end_time - start_time;

                const method = @tagName(ctx.req.head.method);
                const path = ctx.req.head.target;

                std.debug.print("[Performance] {s} {s} - {d}ms\n", .{ method, path, duration });
            }
        }
    };

    return zfinal.Interceptor{
        .name = "performance",
        .before_ud = Impl.before,
        .after_ud = Impl.after,
    };
}

/// 异常处理拦截器
pub fn createExceptionInterceptor() zfinal.Interceptor {
    const Impl = struct {
        fn before(_: *zfinal.Context, _: ?*anyopaque) !bool {
            return true;
        }

        fn after(ctx: *zfinal.Context, _: ?*anyopaque) !void {
            if (ctx.res_status == .internal_server_error) {
                std.debug.print("[Exception] Internal server error on {s}\n", .{ctx.req.head.target});
            }
        }
    };

    return zfinal.Interceptor{
        .name = "exception",
        .before_ud = Impl.before,
        .after_ud = Impl.after,
    };
}

/// 请求日志拦截器（扩展版）
pub fn createAccessLogInterceptor() zfinal.Interceptor {
    const Impl = struct {
        fn before(ctx: *zfinal.Context, _: ?*anyopaque) !bool {
            const timestamp = TimeKit.now();
            var buf: [32]u8 = undefined;
            const ts_str = try std.fmt.bufPrint(&buf, "{d}", .{timestamp});
            try ctx.setAttr("_request_time", ts_str);
            return true;
        }

        fn after(ctx: *zfinal.Context, _: ?*anyopaque) !void {
            const method = @tagName(ctx.req.head.method);
            const path = ctx.req.head.target;
            const status = @backingInt(ctx.res_status);
            const user_agent = ctx.getHeader("User-Agent") orelse "Unknown";
            var ip_buf: [64]u8 = undefined;
            // Secure default: do not trust spoofable proxy headers in access logs.
            const client_ip = IpExt.resolveClientIp(ctx, &ip_buf, .{}) catch "unknown";

            std.debug.print("[Access] {s} - {s} {s} - {d} - UA: {s}\n", .{
                client_ip,
                method,
                path,
                status,
                user_agent,
            });
        }
    };

    return zfinal.Interceptor{
        .name = "access_log",
        .before_ud = Impl.before,
        .after_ud = Impl.after,
    };
}

/// GET **hit-only** response cache (CacheKit) — not a full HTTP cache layer.
///
/// **Before**: on GET cache hit → `renderText` + `return false` (short-circuit).
/// **After store**: **only** when `ctx.capture` is set (oneshot / in-process tests).
/// Live TCP responses do **not** buffer the body for re-store — use `CacheKit` in the
/// handler, or run behind a reverse-proxy cache. Prefer `auto_store = false` on TCP apps
/// unless you only rely on pre-warmed keys / handler writes.
pub const CacheInterceptorConfig = struct {
    cache: *zfinal.CacheKit,
    /// Key prefix; full key = prefix + `GET:` + path (no query).
    key_prefix: []const u8 = "zf:http:",
    ttl_sec: i64 = 60,
    /// When true, attempt after-store (still no-op on live TCP without `ctx.capture`).
    auto_store: bool = true,
};

/// GET hit short-circuit interceptor. See `CacheInterceptorConfig` for TCP store limits.
pub fn createCacheInterceptor(cfg: *const CacheInterceptorConfig) zfinal.Interceptor {
    return createCacheInterceptorWithOptions(cfg);
}

pub fn createCacheInterceptorWithOptions(cfg: *const CacheInterceptorConfig) zfinal.Interceptor {
    return zfinal.Interceptor{
        .name = "cache",
        .userdata = @constCast(cfg),
        .before_ud = struct {
            fn before(ctx: *zfinal.Context, ud: ?*anyopaque) !bool {
                const c: *const CacheInterceptorConfig = @ptrCast(@alignCast(ud.?));
                if (ctx.req.head.method != .GET) return true;
                const target = ctx.req.head.target;
                const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
                var key_buf: [512]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "{s}GET:{s}", .{ c.key_prefix, path }) catch return true;
                if (c.cache.get(key)) |hit| {
                    try ctx.setHeader("X-Cache", "HIT");
                    try ctx.renderText(hit);
                    return false;
                }
                try ctx.setAttr("_cache_key", key);
                try ctx.setHeader("X-Cache", "MISS");
                return true;
            }
        }.before,
        .after_ud = struct {
            fn after(ctx: *zfinal.Context, ud: ?*anyopaque) !void {
                const c: *const CacheInterceptorConfig = @ptrCast(@alignCast(ud.?));
                if (ctx.req.head.method != .GET) return;
                if (ctx.res_status != .ok) return;
                if (!c.auto_store and ctx.getAttr("_cache_store") == null) return;
                const key = ctx.getAttr("_cache_key") orelse return;
                // Capture-mode only (no TCP body buffer).
                if (ctx.capture) |cap| {
                    if (cap.body.items.len == 0) return;
                    c.cache.set(key, cap.body.items, c.ttl_sec) catch {};
                }
            }
        }.after,
    };
}

/// Rate-limit as a before-interceptor. Stops the chain when limiter returns 429.
pub fn createRateLimitInterceptor(limiter: *zfinal.RateLimitHandler) zfinal.Interceptor {
    return zfinal.Interceptor{
        .name = "rate_limit",
        .userdata = limiter,
        .before_ud = struct {
            fn before(ctx: *zfinal.Context, ud: ?*anyopaque) !bool {
                const lim: *zfinal.RateLimitHandler = @ptrCast(@alignCast(ud.?));
                lim.handle(ctx) catch |err| {
                    const path = if (std.mem.indexOfScalar(u8, ctx.req.head.target, '?')) |q|
                        ctx.req.head.target[0..q]
                    else
                        ctx.req.head.target;
                    zfinal.auditLog(.rate_limited, path, "429");
                    return err;
                };
                return true;
            }
        }.before,
    };
}
