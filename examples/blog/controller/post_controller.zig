const std = @import("std");
const zfinal = @import("zfinal");

/// Post Controller
pub const PostController = struct {
    /// 文章列表
    pub fn index(ctx: *zfinal.Context) !void {
        const page = try ctx.getParaToIntDefault("page", 1);
        const page_size = try ctx.getParaToIntDefault("page_size", 10);

        try ctx.renderJson(.{
            .message = "Post list",
            .page = page,
            .page_size = page_size,
            .posts = .{},
        });
    }

    /// 获取文章详情
    pub fn show(ctx: *zfinal.Context) !void {
        const id_str = ctx.getPathParam("id") orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing post ID" });
            return;
        };

        const id = std.fmt.parseInt(i64, id_str, 10) catch {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Invalid post ID" });
            return;
        };

        try ctx.renderJson(.{
            .id = id,
            .title = "Sample Post",
            .content = "This is a sample blog post.",
            .author_id = 1,
            .published = true,
        });
    }

    /// 创建文章
    pub fn create(ctx: *zfinal.Context) !void {
        const title = (try ctx.getPara("title")) orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing title" });
            return;
        };

        const content = (try ctx.getPara("content")) orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing content" });
            return;
        };

        // 验证
        var validator = zfinal.Validator.init(ctx.allocator);
        defer validator.deinit();

        try validator.validateRequired("title", title);
        try validator.validateMinLength("title", title, 1);
        try validator.validateMaxLength("title", title, 200);
        try validator.validateRequired("content", content);

        if (validator.hasErrors()) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .errors = validator });
            return;
        }

        try ctx.renderJson(.{
            .message = "Post created",
            .title = title,
        });
    }

    /// 更新文章
    pub fn update(ctx: *zfinal.Context) !void {
        const id_str = ctx.getPathParam("id") orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing post ID" });
            return;
        };

        const title = try ctx.getPara("title");
        const content = try ctx.getPara("content");

        try ctx.renderJson(.{
            .message = "Post updated",
            .id = id_str,
            .title = title,
            .content = content,
        });
    }

    /// 删除文章
    pub fn delete(ctx: *zfinal.Context) !void {
        const id_str = ctx.getPathParam("id") orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing post ID" });
            return;
        };

        try ctx.renderJson(.{
            .message = "Post deleted",
            .id = id_str,
        });
    }
};
