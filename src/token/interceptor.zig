const std = @import("std");
const Interceptor = @import("../interceptor/interceptor.zig").Interceptor;
const Context = @import("../core/context.zig").Context;
const TokenManager = @import("token.zig").TokenManager;
const audit = @import("../core/audit.zig");
const http_error = @import("../core/http_error.zig");

/// Token 拦截器配置（调用方持有，须长于 Interceptor）
pub const TokenInterceptorConfig = struct {
    token_manager: *TokenManager,
    token_name: []const u8 = "_token",
    error_message: []const u8 = "Invalid or expired token",
};

/// 创建 Token 拦截器。`cfg` 须由调用方持有至进程退出 / app.deinit。
pub fn createTokenInterceptor(cfg: *const TokenInterceptorConfig) Interceptor {
    return Interceptor{
        .name = "token",
        .userdata = @constCast(cfg),
        .before_ud = struct {
            fn before(ctx: *Context, ud: ?*anyopaque) !bool {
                const c: *const TokenInterceptorConfig = @ptrCast(@alignCast(ud.?));
                const path = if (std.mem.indexOfScalar(u8, ctx.req.head.target, '?')) |q|
                    ctx.req.head.target[0..q]
                else
                    ctx.req.head.target;

                const token_value = try ctx.getPara(c.token_name) orelse {
                    audit.log(.csrf_reject, path, "missing");
                    http_error.setDetail(ctx, c.token_name);
                    return error.BadRequest;
                };

                const valid = try c.token_manager.validate(token_value);
                if (!valid) {
                    audit.log(.csrf_reject, path, "invalid");
                    http_error.setDetail(ctx, c.error_message);
                    return error.BadRequest;
                }
                return true;
            }
        }.before,
    };
}

/// Context 扩展：Token 方法
pub const TokenContextMixin = struct {
    pub fn setToken(ctx: *Context, token_manager: *TokenManager) !void {
        const token = try token_manager.generate();
        try ctx.setAttr("_token", token);
    }

    pub fn getToken(ctx: *Context) ?[]const u8 {
        return ctx.getAttr("_token");
    }
};
