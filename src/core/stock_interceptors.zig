//! Stock interceptors (tower-http style layers as ZFinal Interceptors).
const std = @import("std");
const Interceptor = @import("../interceptor/interceptor.zig").Interceptor;
const Context = @import("context.zig").Context;
const extension = @import("extension.zig");
const getLog = @import("logger.zig").getLogger;

pub const BodyLimitConfig = struct { max_bytes: usize };
pub const TimeoutConfig = struct { timeout_ms: u64 };
pub const CompressionConfig = struct { enabled: bool };

/// Cap `ctx.max_body_size`. `cfg` must outlive the interceptor.
pub fn createBodyLimitInterceptor(cfg: *const BodyLimitConfig) Interceptor {
    return .{
        .name = "body_limit",
        .userdata = @constCast(cfg),
        .before_ud = struct {
            fn before(ctx: *Context, ud: ?*anyopaque) !bool {
                const limit = @as(*const BodyLimitConfig, @ptrCast(@alignCast(ud.?))).max_bytes;
                ctx.max_body_size = @min(ctx.max_body_size, limit);
                return true;
            }
        }.before,
    };
}

/// Shorten the per-request handler deadline (ms). 0 = no-op.
pub fn createTimeoutInterceptor(cfg: *const TimeoutConfig) Interceptor {
    return .{
        .name = "timeout",
        .userdata = @constCast(cfg),
        .before_ud = struct {
            fn before(ctx: *Context, ud: ?*anyopaque) !bool {
                const ms = @as(*const TimeoutConfig, @ptrCast(@alignCast(ud.?))).timeout_ms;
                if (ms > 0) ctx.setTimeoutMs(ms);
                return true;
            }
        }.before,
    };
}

/// Force gzip/deflate negotiation on/off for this request.
pub fn createCompressionInterceptor(cfg: *const CompressionConfig) Interceptor {
    return .{
        .name = "compression",
        .userdata = @constCast(cfg),
        .before_ud = struct {
            fn before(ctx: *Context, ud: ?*anyopaque) !bool {
                ctx.compress_enabled = @as(*const CompressionConfig, @ptrCast(@alignCast(ud.?))).enabled;
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

test "body limit interceptor uses distinct caller-owned configs" {
    const a_cfg = BodyLimitConfig{ .max_bytes = 1024 };
    const b_cfg = BodyLimitConfig{ .max_bytes = 2048 };
    const a = createBodyLimitInterceptor(&a_cfg);
    const b = createBodyLimitInterceptor(&b_cfg);
    try std.testing.expect(a.userdata != b.userdata);
    const t_cfg = TimeoutConfig{ .timeout_ms = 100 };
    const c_cfg = CompressionConfig{ .enabled = false };
    _ = createTimeoutInterceptor(&t_cfg);
    _ = createCompressionInterceptor(&c_cfg);
    _ = createTraceInterceptor();
}
