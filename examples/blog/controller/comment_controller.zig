const std = @import("std");
const zfinal = @import("zfinal");

/// Comment Controller
pub const CommentController = struct {
    /// 获取文章的评论
    pub fn index(ctx: *zfinal.Context) !void {
        const post_id = ctx.getPathParam("post_id") orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing post ID" });
            return;
        };

        try ctx.renderJson(.{
            .message = "Comments for post",
            .post_id = post_id,
            .comments = .{},
        });
    }

    /// 创建评论
    pub fn create(ctx: *zfinal.Context) !void {
        const post_id = ctx.getPathParam("post_id") orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing post ID" });
            return;
        };

        const content = (try ctx.getPara("content")) orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing content" });
            return;
        };

        try ctx.renderJson(.{
            .message = "Comment created",
            .post_id = post_id,
            .content = content,
        });
    }
};
