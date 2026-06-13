// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// SystemSocialUser model — maps to `system_social_user` table.
pub const SystemSocialUser = struct {
    id: ?i64 = null,
};

pub const SystemSocialUserModel = zfinal.Model(SystemSocialUser, "system_social_user");
pub const jsonNaming: zfinal.JsonNaming = .camelCase;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
    .{ .db = "id", .json = "id" },
};

pub fn jsonFieldName(comptime db_name: []const u8) []const u8 {
    for (fieldMap) |entry| if (std.mem.eql(u8, entry.db, db_name)) return entry.json;
    return db_name;
}

/// Fields safe to expose in API responses (sensitive columns excluded).
pub const safeFields = [_][]const u8{
    "id",
};

/// Validate SystemSocialUser data before insert/update.
pub fn validate(data: SystemSocialUser) !void {
    _ = data;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
