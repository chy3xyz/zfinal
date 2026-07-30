//! Stock interceptors (tower-http style layers as ZFinal Interceptors).
const std = @import("std");
const Interceptor = @import("../interceptor/interceptor.zig").Interceptor;
const heapCfg = @import("../interceptor/interceptor.zig").heapCfg;
const Context = @import("context.zig").Context;
const extension = @import("extension.zig");
const getLog = @import("logger.zig").getLogger;

/// Cap `ctx.max_body_size` for routes that opt in (global ServerConfig remains the ceiling).
pub fn createBodyLimitInterceptor(max_bytes: usize) Interceptor {
    const cfg = heapCfg(usize, max_bytes);
    return .{
        .name = "body_limit",
        .userdata = cfg,
        .before_ud = struct {
            fn before(ctx: *Context, ud: ?*anyopaque) !bool {
                const limit = @as(*usize, @ptrCast(@alignCast(ud.?))).*;
                ctx.max_body_size = @min(ctx.max_body_size, limit);
                return true;
            }
        }.before,
    };
}

/// Shorten the per-request handler deadline (ms). 0 = no-op.
pub fn createTimeoutInterceptor(timeout_ms: u64) Interceptor {
    const cfg = heapCfg(u64, timeout_ms);
    return .{
        .name = "timeout",
        .userdata = cfg,
        .before_ud = struct {
            fn before(ctx: *Context, ud: ?*anyopaque) !bool {
                const ms = @as(*u64, @ptrCast(@alignCast(ud.?))).*;
                if (ms > 0) ctx.setTimeoutMs(ms);
                return true;
            }
        }.before,
    };
}

/// Force gzip/deflate negotiation on/off for this request.
pub fn createCompressionInterceptor(enabled: bool) Interceptor {
    const cfg = heapCfg(bool, enabled);
    return .{
        .name = "compression",
        .userdata = cfg,
        .before_ud = struct {
            fn before(ctx: *Context, ud: ?*anyopaque) !bool {
                ctx.compress_enabled = @as(*bool, @ptrCast(@alignCast(ud.?))).*;
                return true;
            }
        }.before,
    };
}

/// Structured access log (method, path, status) after the handler — TraceLayer-lite.
pub fn createTraceInterceptor() Interceptor {
    return .{
        .name = "trace",
        .before = struct {
            fn before(ctx: *Context) !bool {
                const target = ctx.req.head.target;
                const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
                try ctx.setExt(extension.TraceMeta, .{
                    .method = @tagName(ctx.req.head.method),
                    .path = path,
                });
                return true;
            }
        }.before,
        .after = struct {
            fn after(ctx: *Context) !void {
                const meta = ctx.ext(extension.TraceMeta);
                const method = if (meta) |m| m.method else "?";
                const path = if (meta) |m| m.path else "?";
                const rid = if (ctx.ext(extension.RequestId)) |r| r.value else ctx.getAttr("request_id") orelse "-";
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
    const a = createBodyLimitInterceptor(1024);
    const b = createBodyLimitInterceptor(2048);
    try std.testing.expect(a.userdata != b.userdata);
    _ = createTimeoutInterceptor(100);
    _ = createCompressionInterceptor(false);
    _ = createTraceInterceptor();
}
