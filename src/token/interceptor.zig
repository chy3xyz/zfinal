const std = @import("std");
const Interceptor = @import("../interceptor/interceptor.zig").Interceptor;
const Context = @import("../core/context.zig").Context;
const TokenManager = @import("token.zig").TokenManager;

/// Token 拦截器配置
pub const TokenInterceptorConfig = struct {
    token_manager: *TokenManager,
    token_name: []const u8 = "_token",
    error_message: []const u8 = "Invalid or expired token",
};

/// 创建 Token 拦截器
pub fn createTokenInterceptor(config: TokenInterceptorConfig) Interceptor {
    const InterceptorImpl = struct {
        var cfg: TokenInterceptorConfig = undefined;

        fn before(ctx: *Context) !bool {
            // 获取 Token
            const token_value = try ctx.getPara(cfg.token_name) orelse {
                ctx.res_status = .bad_request;
                try ctx.renderJson(.{ .@"error" = "Missing token" });
                return false;
            };

            // 验证 Token
            const valid = try cfg.token_manager.validate(token_value);
            if (!valid) {
                ctx.res_status = .bad_request;
                try ctx.renderJson(.{ .@"error" = cfg.error_message });
                return false;
            }
            return true;
        }
    };

    InterceptorImpl.cfg = config;

    return Interceptor{
        .name = "token",
        .before = InterceptorImpl.before,
    };
}

/// Context 扩展：Token 方法
pub const TokenContextMixin = struct {
    /// 生成并设置 Token 到 Context
    pub fn setToken(ctx: *Context, token_manager: *TokenManager) !void {
        const token = try token_manager.generate();
        try ctx.setAttr("_token", token);
    }

    /// 获取 Token
    pub fn getToken(ctx: *Context) ?[]const u8 {
        return ctx.getAttr("_token");
    }
};
