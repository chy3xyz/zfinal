const std = @import("std");
const zfinal = @import("../main.zig");

/// 渲染工具扩展
pub const RenderExt = struct {
    /// 渲染成功响应
    pub fn success(ctx: *zfinal.Context, data: anytype) !void {
        try ctx.renderJson(.{
            .success = true,
            .data = data,
        });
    }

    /// 渲染错误响应
    pub fn err(ctx: *zfinal.Context, message: []const u8) !void {
        try ctx.renderJson(.{
            .success = false,
            .err = message,
        });
    }

    /// 渲染分页响应
    pub fn page(ctx: *zfinal.Context, list: anytype, total: i64, page_num: i64, page_size: i64) !void {
        try ctx.renderJson(.{
            .success = true,
            .data = .{
                .list = list,
                .total = total,
                .page = page_num,
                .page_size = page_size,
                .total_pages = @divTrunc(total + page_size - 1, page_size),
            },
        });
    }
};

/// 参数验证扩展
pub const ParamExt = struct {
    /// 获取必需参数
    pub fn require(ctx: *zfinal.Context, name: []const u8) ![]const u8 {
        return ctx.getParam(name) orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .err = "Missing required parameter" });
            return error.MissingParameter;
        };
    }

    /// 获取整数参数（必需）
    pub fn requireInt(ctx: *zfinal.Context, name: []const u8) !i64 {
        const value = try require(ctx, name);
        return std.fmt.parseInt(i64, value, 10) catch {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .err = "Invalid integer parameter" });
            return error.InvalidParameter;
        };
    }

    /// 获取整数参数（可选，带默认值）
    pub fn getIntOr(ctx: *zfinal.Context, name: []const u8, default_value: i64) i64 {
        const value = ctx.getParam(name) orelse return default_value;
        return std.fmt.parseInt(i64, value, 10) catch default_value;
    }
};

/// Session 扩展
pub const SessionExt = struct {
    /// 获取当前用户 ID
    pub fn getUserId(ctx: *zfinal.Context) ?i64 {
        const user_id_str = ctx.getSessionAttr("user_id") orelse return null;
        return std.fmt.parseInt(i64, user_id_str, 10) catch null;
    }

    /// 设置当前用户 ID
    pub fn setUserId(ctx: *zfinal.Context, user_id: i64) !void {
        const user_id_str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{user_id});
        try ctx.setSessionAttr("user_id", user_id_str);
    }

    /// 检查是否登录
    pub fn isLoggedIn(ctx: *zfinal.Context) bool {
        return getUserId(ctx) != null;
    }

    /// 登出
    pub fn logout(ctx: *zfinal.Context) !void {
        try ctx.removeSessionAttr("user_id");
    }
};
