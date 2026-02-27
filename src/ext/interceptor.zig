const std = @import("std");
const zfinal = @import("../main.zig");

/// 性能监控拦截器
pub fn createPerformanceInterceptor() zfinal.Interceptor {
    const Impl = struct {
        fn before(ctx: *zfinal.Context) !bool {
            const start_time = std.time.milliTimestamp();
            try ctx.setAttr("_start_time", try std.fmt.allocPrint(ctx.allocator, "{d}", .{start_time}));
            return true;
        }

        fn after(ctx: *zfinal.Context) !void {
            if (ctx.getAttr("_start_time")) |start_str| {
                defer ctx.allocator.free(start_str);

                const start_time = try std.fmt.parseInt(i64, start_str, 10);
                const end_time = std.time.milliTimestamp();
                const duration = end_time - start_time;

                const method = @tagName(ctx.req.head.method);
                const path = ctx.req.head.target;

                std.debug.print("[Performance] {s} {s} - {d}ms\n", .{ method, path, duration });
            }
        }
    };

    return zfinal.Interceptor{
        .name = "performance",
        .before = Impl.before,
        .after = Impl.after,
    };
}

/// 异常处理拦截器
pub fn createExceptionInterceptor() zfinal.Interceptor {
    const Impl = struct {
        fn before(_: *zfinal.Context) !bool {
            // 不需要 before 处理
            return true;
        }

        fn after(ctx: *zfinal.Context) !void {
            // 异常已在 handler 中处理，这里可以记录日志
            if (ctx.res_status == .internal_server_error) {
                std.debug.print("[Exception] Internal server error on {s}\n", .{ctx.req.head.target});
            }
        }
    };

    return zfinal.Interceptor{
        .name = "exception",
        .before = Impl.before,
        .after = Impl.after,
    };
}

/// 请求日志拦截器（扩展版）
pub fn createAccessLogInterceptor() zfinal.Interceptor {
    const Impl = struct {
        fn before(ctx: *zfinal.Context) !bool {
            const timestamp = std.time.timestamp();
            try ctx.setAttr("_request_time", try std.fmt.allocPrint(ctx.allocator, "{d}", .{timestamp}));
            return true;
        }

        fn after(ctx: *zfinal.Context) !void {
            const method = @tagName(ctx.req.head.method);
            const path = ctx.req.head.target;
            const status = @intFromEnum(ctx.res_status);
            const user_agent = ctx.getHeader("User-Agent") orelse "Unknown";
            const client_ip = ctx.getHeader("X-Real-IP") orelse ctx.getHeader("X-Forwarded-For") orelse "unknown";

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
        .before = Impl.before,
        .after = Impl.after,
    };
}

/// 缓存拦截器
pub fn createCacheInterceptor(cache: *zfinal.CacheKit) zfinal.Interceptor {
    _ = cache; // TODO: 实现缓存逻辑

    const Impl = struct {
        fn before(_: *zfinal.Context) !bool {
            // TODO: 检查缓存
            return true;
        }

        fn after(_: *zfinal.Context) !void {
            // TODO: 存储缓存
        }
    };

    return zfinal.Interceptor{
        .name = "cache",
        .before = Impl.before,
        .after = Impl.after,
    };
}
