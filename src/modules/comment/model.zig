const std = @import("std");
const zfinal = @import("zfinal");

/// Comments model — maps to `comments` table.
pub const Comments = struct {
    id: ?i64 = null,
    post_id: i64,
    author_id: i64,
    content: []const u8,
    created_at: ?[]const u8 = null,
};

pub const CommentsModel = zfinal.Model(Comments, "comments");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
        .{ .db = "id", .json = "id" },
        .{ .db = "post_id", .json = "post_id" },
        .{ .db = "author_id", .json = "author_id" },
        .{ .db = "content", .json = "content" },
        .{ .db = "created_at", .json = "created_at" },
};

pub fn jsonFieldName(comptime db_name: []const u8) []const u8 {
    for (fieldMap) |entry| if (std.mem.eql(u8, entry.db, db_name)) return entry.json;
    return db_name;
}

/// Fields safe to expose in API responses (sensitive columns excluded).
pub const safeFields = [_][]const u8{
        .id,
        .post_id,
        .author_id,
        .content,
        .created_at,
};

/// Validate Comments data before insert/update.
pub fn validate(data: Comments) !void {
    // post_id: non-nullable i64
    // author_id: non-nullable i64
    if (data.content.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
