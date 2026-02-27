const std = @import("std");
const zfinal = @import("zfinal");

/// User Controller
pub const UserController = struct {
    /// 用户列表
    pub fn index(ctx: *zfinal.Context) !void {
        try ctx.renderJson(.{
            .message = "User list",
            .users = .{},
        });
    }

    /// 获取用户详情
    pub fn show(ctx: *zfinal.Context) !void {
        const id_str = ctx.getPathParam("id") orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing user ID" });
            return;
        };

        const id = std.fmt.parseInt(i64, id_str, 10) catch {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Invalid user ID" });
            return;
        };

        try ctx.renderJson(.{
            .id = id,
            .username = "demo_user",
            .email = "demo@example.com",
        });
    }

    /// 创建用户
    pub fn create(ctx: *zfinal.Context) !void {
        const username = (try ctx.getPara("username")) orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing username" });
            return;
        };

        const email = (try ctx.getPara("email")) orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing email" });
            return;
        };

        const password = (try ctx.getPara("password")) orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing password" });
            return;
        };

        // 验证
        var validator = zfinal.Validator.init(ctx.allocator);
        defer validator.deinit();

        try validator.validateRequired("username", username);
        try validator.validateEmail("email", email);
        try validator.validateMinLength("password", password, 6);
        try validator.validateMaxLength("password", password, 100);

        if (validator.hasErrors()) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .errors = validator });
            return;
        }

        try ctx.renderJson(.{
            .message = "User created",
            .username = username,
            .email = email,
        });
    }
};
