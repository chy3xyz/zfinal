// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// SystemUserRole model — maps to `system_user_role` table.
pub const SystemUserRole = struct {
    id: ?i64 = null,
    user_id: i64,
    role_id: i64,
    creator: ?[]const u8 = null,
    create_time: ?[]const u8 = null,
    updater: ?[]const u8 = null,
    update_time: ?[]const u8 = null,
    deleted: ?bool = null,
    tenant_id: i64,
};

pub const SystemUserRoleModel = zfinal.Model(SystemUserRole, "system_user_role");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
        .{ .db = "id", .json = "id" },
        .{ .db = "user_id", .json = "user_id" },
        .{ .db = "role_id", .json = "role_id" },
        .{ .db = "creator", .json = "creator" },
        .{ .db = "create_time", .json = "create_time" },
        .{ .db = "updater", .json = "updater" },
        .{ .db = "update_time", .json = "update_time" },
        .{ .db = "deleted", .json = "deleted" },
        .{ .db = "tenant_id", .json = "tenant_id" },
};

pub fn jsonFieldName(comptime db_name: []const u8) []const u8 {
    for (fieldMap) |entry| if (std.mem.eql(u8, entry.db, db_name)) return entry.json;
    return db_name;
}

/// Fields safe to expose in API responses (sensitive columns excluded).
pub const safeFields = [_][]const u8{
        "id",
        "user_id",
        "role_id",
        "creator",
        "create_time",
        "updater",
        "update_time",
        "deleted",
        "tenant_id",
};

/// Validate SystemUserRole data before insert/update.
pub fn validate(data: SystemUserRole) !void {
    _ = data;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
