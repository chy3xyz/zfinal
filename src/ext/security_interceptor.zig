const std = @import("std");
const zfinal = @import("../main.zig");
const RandomKit = @import("../kit/random_kit.zig").RandomKit;

pub const SecurityHeadersConfig = struct {
    include_hsts: bool = true,
};

/// Set standard security response headers. `cfg` must outlive the interceptor.
pub fn createSecurityHeadersInterceptor(cfg: *const SecurityHeadersConfig) zfinal.Interceptor {
    return zfinal.Interceptor{
        .name = "security_headers",
        .userdata = @constCast(cfg),
        .before_ud = struct {
            fn before(ctx: *zfinal.Context, ud: ?*anyopaque) !bool {
                const hsts = @as(*const SecurityHeadersConfig, @ptrCast(@alignCast(ud.?))).include_hsts;
                try ctx.setHeader("X-Content-Type-Options", "nosniff");
                try ctx.setHeader("X-Frame-Options", "DENY");
                try ctx.setHeader("Referrer-Policy", "strict-origin-when-cross-origin");
                try ctx.setHeader("X-XSS-Protection", "1; mode=block");
                if (hsts) {
                    try ctx.setHeader("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
                }
                return true;
            }
        }.before,
    };
}

/// Propagate or generate `X-Request-Id`; sets attr + typed `extension.RequestId`.
pub fn createRequestIdInterceptor() zfinal.Interceptor {
    return zfinal.Interceptor{
        .name = "request_id",
        .before_ud = struct {
            fn before(ctx: *zfinal.Context, _: ?*anyopaque) !bool {
                const id = if (ctx.getHeader("X-Request-Id")) |i|
                    try ctx.allocator.dupe(u8, i)
                else
                    try RandomKit.uuid(ctx.allocator);
                defer ctx.allocator.free(id);
                try ctx.setAttr("request_id", id);
                try ctx.setHeader("X-Request-Id", id);
                const rid = ctx.getAttr("request_id").?;
                try ctx.setExt(zfinal.extension.RequestId, .{ .value = rid });
                return true;
            }
        }.before,
    };
}
