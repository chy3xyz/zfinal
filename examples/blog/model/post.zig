const std = @import("std");
const zfinal = @import("zfinal");

/// Post Model
pub const Post = struct {
    title: []const u8,
    content: []const u8,
    author_id: i64,
    published: bool = false,
    created_at: ?[]const u8 = null,
};

pub const PostModel = zfinal.Model(Post, "posts");
