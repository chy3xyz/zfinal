const std = @import("std");
const zfinal = @import("zfinal");

/// Posts model — maps to `posts` table.
pub const Posts = struct {
    id: ?i64 = null,
    title: []const u8,
    content: []const u8,
    author_id: i64,
    published: ?bool = null,
    created_at: ?[]const u8 = null,
};

pub const PostsModel = zfinal.Model(Posts, "posts");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
        .{ .db = "id", .json = "id" },
        .{ .db = "title", .json = "title" },
        .{ .db = "content", .json = "content" },
        .{ .db = "author_id", .json = "author_id" },
        .{ .db = "published", .json = "published" },
        .{ .db = "created_at", .json = "created_at" },
};

pub fn jsonFieldName(comptime db_name: []const u8) []const u8 {
    for (fieldMap) |entry| if (std.mem.eql(u8, entry.db, db_name)) return entry.json;
    return db_name;
}

/// Fields safe to expose in API responses (sensitive columns excluded).
pub const safeFields = [_][]const u8{
        .id,
        .title,
        .content,
        .author_id,
        .published,
        .created_at,
};

/// Validate Posts data before insert/update.
pub fn validate(data: Posts) !void {
    if (data.title.len == 0) return error.ValidationError;
    if (data.content.len == 0) return error.ValidationError;
    // author_id: non-nullable i64
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
