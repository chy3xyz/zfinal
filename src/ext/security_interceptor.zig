const std = @import("std");
const zfinal = @import("../main.zig");
const RandomKit = @import("../kit/random_kit.zig").RandomKit;

/// Set standard security response headers (nosniff, frame deny, XSS, optional HSTS).
pub fn createSecurityHeadersInterceptor(include_hsts: bool) zfinal.Interceptor {
    const Impl = struct {
        var hsts: bool = true;

        fn before(ctx: *zfinal.Context) !bool {
            try ctx.setHeader("X-Content-Type-Options", "nosniff");
            try ctx.setHeader("X-Frame-Options", "DENY");
            try ctx.setHeader("Referrer-Policy", "strict-origin-when-cross-origin");
            try ctx.setHeader("X-XSS-Protection", "1; mode=block");
            if (hsts) {
                try ctx.setHeader("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
            }
            return true;
        }
    };
    Impl.hsts = include_hsts;
    return zfinal.Interceptor{
        .name = "security_headers",
        .before = Impl.before,
    };
}

/// Propagate or generate `X-Request-Id`; sets attr + typed `extension.RequestId`.
pub fn createRequestIdInterceptor() zfinal.Interceptor {
    const Impl = struct {
        fn before(ctx: *zfinal.Context) !bool {
            const id = if (ctx.getHeader("X-Request-Id")) |i|
                try ctx.allocator.dupe(u8, i)
            else
                try RandomKit.uuid(ctx.allocator);
            defer ctx.allocator.free(id);
            try ctx.setAttr("request_id", id);
            try ctx.setHeader("X-Request-Id", id);
            // Attr owns a copy; Extension points at the attr lifetime.
            const rid = ctx.getAttr("request_id").?;
            try ctx.setExt(zfinal.extension.RequestId, .{ .value = rid });
            return true;
        }
    };
    return zfinal.Interceptor{
        .name = "request_id",
        .before = Impl.before,
    };
}
