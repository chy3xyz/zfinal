const std = @import("std");
const zfinal = @import("zfinal");

/// 日志拦截器
fn loggingBefore(ctx: *zfinal.Context) !bool {
    const method = @tagName(ctx.req.head.method);
    const path = ctx.req.head.target;
    std.debug.print("[{s}] {s}\n", .{ method, path });
    return true;
}

pub const LoggingInterceptor = zfinal.Interceptor{
    .name = "logging",
    .before = loggingBefore,
};

/// 认证拦截器
fn authBefore(ctx: *zfinal.Context) !bool {
    const token = ctx.getHeader("Authorization");
    if (token == null) {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "Unauthorized" });
        return error.Unauthorized;
    }
    return true;
}

pub const AuthInterceptor = zfinal.Interceptor{
    .name = "auth",
    .before = authBefore,
};
