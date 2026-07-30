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

/// 认证拦截器 — 失败走 HttpError，由 dispatch 渲染
fn authBefore(ctx: *zfinal.Context) !bool {
    if (ctx.getHeader("Authorization") == null) {
        zfinal.http_error.setDetail(ctx, "Authorization");
        return error.Unauthorized;
    }
    return true;
}

pub const AuthInterceptor = zfinal.Interceptor{
    .name = "auth",
    .before = authBefore,
};
