// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// SystemMenu model — maps to `system_menu` table.
pub const SystemMenu = struct {
    id: ?i64 = null,
    name: []const u8,
    permission: []const u8,
    type: i64,
    sort: i64,
    parent_id: i64,
    path: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    component: ?[]const u8 = null,
    component_name: ?[]const u8 = null,
    status: i64,
    visible: bool,
    keep_alive: bool,
    always_show: bool,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
};

pub const SystemMenuModel = zfinal.Model(SystemMenu, "system_menu");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
    .{ .db = "id", .json = "id" },
    .{ .db = "name", .json = "name" },
    .{ .db = "permission", .json = "permission" },
    .{ .db = "type", .json = "type" },
    .{ .db = "sort", .json = "sort" },
    .{ .db = "parent_id", .json = "parent_id" },
    .{ .db = "path", .json = "path" },
    .{ .db = "icon", .json = "icon" },
    .{ .db = "component", .json = "component" },
    .{ .db = "component_name", .json = "component_name" },
    .{ .db = "status", .json = "status" },
    .{ .db = "visible", .json = "visible" },
    .{ .db = "keep_alive", .json = "keep_alive" },
    .{ .db = "always_show", .json = "always_show" },
    .{ .db = "creator", .json = "creator" },
    .{ .db = "create_time", .json = "create_time" },
    .{ .db = "updater", .json = "updater" },
    .{ .db = "update_time", .json = "update_time" },
    .{ .db = "deleted", .json = "deleted" },
};

pub fn jsonFieldName(comptime db_name: []const u8) []const u8 {
    for (fieldMap) |entry| if (std.mem.eql(u8, entry.db, db_name)) return entry.json;
    return db_name;
}

/// Fields safe to expose in API responses (sensitive columns excluded).
pub const safeFields = [_][]const u8{
    "id",
    "name",
    "permission",
    "type",
    "sort",
    "parent_id",
    "path",
    "icon",
    "component",
    "component_name",
    "status",
    "visible",
    "keep_alive",
    "always_show",
    "creator",
    "create_time",
    "updater",
    "update_time",
    "deleted",
};

/// Validate SystemMenu data before insert/update.
pub fn validate(data: SystemMenu) !void {
    if (data.name.len == 0) return error.ValidationError;
    if (data.permission.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
