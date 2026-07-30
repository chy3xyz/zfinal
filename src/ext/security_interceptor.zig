const std = @import("std");
const zfinal = @import("../main.zig");
const RandomKit = @import("../kit/random_kit.zig").RandomKit;
const heapCfg = @import("../interceptor/interceptor.zig").heapCfg;

/// Set standard security response headers (nosniff, frame deny, XSS, optional HSTS).
pub fn createSecurityHeadersInterceptor(include_hsts: bool) zfinal.Interceptor {
    const cfg = heapCfg(bool, include_hsts);
    return zfinal.Interceptor{
        .name = "security_headers",
        .userdata = cfg,
        .before_ud = struct {
            fn before(ctx: *zfinal.Context, ud: ?*anyopaque) !bool {
                const hsts = @as(*bool, @ptrCast(@alignCast(ud.?))).*;
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
        .before = struct {
            fn before(ctx: *zfinal.Context) !bool {
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
