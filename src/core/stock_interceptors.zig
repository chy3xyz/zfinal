//! Stock interceptors (tower-http style layers as ZFinal Interceptors).
const std = @import("std");
const Interceptor = @import("../interceptor/interceptor.zig").Interceptor;
const Context = @import("context.zig").Context;
const http_error = @import("http_error.zig");
const extension = @import("extension.zig");
const getLog = @import("logger.zig").getLogger;

/// Cap `ctx.max_body_size` for routes that opt in (global ServerConfig remains the ceiling).
pub fn createBodyLimitInterceptor(max_bytes: usize) Interceptor {
    const Impl = struct {
        var limit: usize = 0;
        fn before(ctx: *Context) !bool {
            ctx.max_body_size = @min(ctx.max_body_size, limit);
            return true;
        }
    };
    Impl.limit = max_bytes;
    return .{ .name = "body_limit", .before = Impl.before };
}

/// Shorten the per-request handler deadline (ms). 0 = no-op.
pub fn createTimeoutInterceptor(timeout_ms: u64) Interceptor {
    const Impl = struct {
        var ms: u64 = 0;
        fn before(ctx: *Context) !bool {
            if (ms > 0) ctx.setTimeoutMs(ms);
            return true;
        }
    };
    Impl.ms = timeout_ms;
    return .{ .name = "timeout", .before = Impl.before };
}

/// Force gzip/deflate negotiation on/off for this request.
pub fn createCompressionInterceptor(enabled: bool) Interceptor {
    const Impl = struct {
        var on: bool = true;
        fn before(ctx: *Context) !bool {
            ctx.compress_enabled = on;
            return true;
        }
    };
    Impl.on = enabled;
    return .{ .name = "compression", .before = Impl.before };
}

/// Structured access log (method, path, status) after the handler — TraceLayer-lite.
pub fn createTraceInterceptor() Interceptor {
    return .{
        .name = "trace",
        .before = struct {
            fn before(ctx: *Context) !bool {
                const target = ctx.req.head.target;
                const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
                try ctx.setAttr("_trace_path", path);
                try ctx.setAttr("_trace_method", @tagName(ctx.req.head.method));
                return true;
            }
        }.before,
        .after = struct {
            fn after(ctx: *Context) !void {
                const method = ctx.getAttr("_trace_method") orelse "?";
                const path = ctx.getAttr("_trace_path") orelse "?";
                const rid = ctx.getAttr("request_id") orelse "-";
                getLog().infoFmt("{s} {s} status={d} request_id={s}", .{
                    method,
                    path,
                    @intFromEnum(ctx.res_status),
                    rid,
                });
            }
        }.after,
    };
}

/// Ensure `request_id` attr exists and expose typed `extension.RequestId`.
pub fn createRequestIdExtInterceptor() Interceptor {
    return .{
        .name = "request_id_ext",
        .before = struct {
            fn before(ctx: *Context) !bool {
                const rid = ctx.getAttr("request_id") orelse return true;
                try extension.putOwned(&ctx.extensions, ctx.allocator, extension.RequestId, .{ .value = rid });
                return true;
            }
        }.before,
    };
}

test "body limit interceptor shrinks max" {
    _ = createBodyLimitInterceptor(1024);
    _ = createTimeoutInterceptor(100);
    _ = createCompressionInterceptor(false);
    _ = createTraceInterceptor();
}
