const std = @import("std");
const zfinal = @import("zfinal");

/// Index Controller
pub const IndexController = struct {
    /// 首页
    pub fn index(ctx: *zfinal.Context) !void {
        try ctx.renderJson(.{
            .message = "Welcome to zfinal Blog!",
            .version = "0.1.0",
            .endpoints = .{
                .users = "/api/users",
                .posts = "/api/posts",
            },
        });
    }
};
