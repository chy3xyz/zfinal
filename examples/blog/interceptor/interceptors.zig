const std = @import("std");
const builtin = @import("builtin");
const zfinal = @import("zfinal");

/// Per-request stderr log. Debug: on by default. Release*: off unless
/// `ZF_REQUEST_LOG=1` — `std.debug.print` serializes all workers and tanks
/// close-mode bench RPS when every request prints.
fn requestLogEnabled() bool {
    if (std.c.getenv("ZF_REQUEST_LOG")) |p| {
        const v = std.mem.span(p);
        return !(std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false") or v.len == 0);
    }
    return builtin.mode == .debug;
}

/// 日志拦截器
fn loggingBefore(ctx: *zfinal.Context) !bool {
    if (!requestLogEnabled()) return true;
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
