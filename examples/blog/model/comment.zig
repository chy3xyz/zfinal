const std = @import("std");
const zfinal = @import("zfinal");

/// Comment Model
pub const Comment = struct {
    post_id: i64,
    author_id: i64,
    content: []const u8,
    created_at: ?[]const u8 = null,
};

pub const CommentModel = zfinal.Model(Comment, "comments");
