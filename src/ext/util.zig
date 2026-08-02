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

    /// 渲染错误响应（统一 HttpError 信封）
    pub fn err(ctx: *zfinal.Context, message: []const u8) !void {
        zfinal.http_error.setDetail(ctx, message);
        try zfinal.http_error.render(ctx, error.BadRequest);
    }

    /// 渲染分页响应
    pub fn page(ctx: *zfinal.Context, list: anytype, total: i64, page_num: i64, page_size: i64) !void {
        std.debug.assert(page_size > 0);
        std.debug.assert(page_num >= 1);
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
    /// 获取必需参数（失败 → HttpError.BadRequest，由 dispatch 渲染）
    pub fn require(ctx: *zfinal.Context, name: []const u8) ![]const u8 {
        const value = try ctx.getPara(name);
        return value orelse {
            zfinal.http_error.setDetail(ctx, name);
            return error.BadRequest;
        };
    }

    /// 获取整数参数（必需）
    pub fn requireInt(ctx: *zfinal.Context, name: []const u8) !i64 {
        const value = try require(ctx, name);
        return std.fmt.parseInt(i64, value, 10) catch {
            zfinal.http_error.setDetail(ctx, name);
            return error.BadRequest;
        };
    }

    /// 获取整数参数（可选，带默认值）
    pub fn getIntOr(ctx: *zfinal.Context, name: []const u8, default_value: i64) i64 {
        const value = ctx.getPara(name) catch return default_value;
        return std.fmt.parseInt(i64, value.?, 10) catch default_value;
    }
};

/// Session 扩展（通过 Context attributes 模拟会话属性）
/// 注意：生产环境应使用 SessionStore 管理会话生命周期和 TTL
pub const SessionExt = struct {
    const SESSION_PREFIX = "session.";

    /// 获取当前用户 ID
    pub fn getUserId(ctx: *zfinal.Context) ?i64 {
        const user_id_str = ctx.getAttr(SESSION_PREFIX ++ "user_id") orelse return null;
        return std.fmt.parseInt(i64, user_id_str, 10) catch null;
    }

    /// 设置当前用户 ID
    pub fn setUserId(ctx: *zfinal.Context, user_id: i64) !void {
        var buf: [32]u8 = undefined;
        const user_id_str = try std.fmt.bufPrint(&buf, "{d}", .{user_id});
        try ctx.setAttr(SESSION_PREFIX ++ "user_id", user_id_str);
    }

    /// 检查是否登录
    pub fn isLoggedIn(ctx: *zfinal.Context) bool {
        return getUserId(ctx) != null;
    }

    /// 登出
    pub fn logout(ctx: *zfinal.Context) !void {
        // Context attributes 不支持删除，设为空字符串表示清除
        try ctx.setAttr(SESSION_PREFIX ++ "user_id", "");
    }
};
