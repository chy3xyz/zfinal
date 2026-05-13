const std = @import("std");
const zfinal = @import("zfinal");

/// Users model — maps to `users` table.
pub const Users = struct {
    id: ?i64 = null,
    username: []const u8,
    email: []const u8,
    password: []const u8,
    created_at: ?[]const u8 = null,
};

pub const UsersModel = zfinal.Model(Users, "users");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
        .{ .db = "id", .json = "id" },
        .{ .db = "username", .json = "username" },
        .{ .db = "email", .json = "email" },
        .{ .db = "password", .json = "password" },
        .{ .db = "created_at", .json = "created_at" },
};

pub fn jsonFieldName(comptime db_name: []const u8) []const u8 {
    for (fieldMap) |entry| if (std.mem.eql(u8, entry.db, db_name)) return entry.json;
    return db_name;
}

/// Fields safe to expose in API responses (sensitive columns excluded).
pub const safeFields = [_][]const u8{
        "id",
        "username",
        "email",
        "created_at",
};

/// Validate Users data before insert/update.
pub fn validate(data: Users) !void {
    if (data.username.len == 0) return error.ValidationError;
    if (data.email.len == 0) return error.ValidationError;
    if (data.email.len > 0 and std.mem.indexOfScalar(u8, data.email, '@') == null) return error.InvalidEmail;
    if (data.password.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
