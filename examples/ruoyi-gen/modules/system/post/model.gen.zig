// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// SystemPost model — maps to `system_post` table.
pub const SystemPost = struct {
    id: ?i64 = null,
    code: []const u8,
    name: []const u8,
    sort: i64,
    status: i64,
    remark: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
    tenant_id: i64,
};

pub const SystemPostModel = zfinal.Model(SystemPost, "system_post");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
    .{ .db = "id", .json = "id" },
    .{ .db = "code", .json = "code" },
    .{ .db = "name", .json = "name" },
    .{ .db = "sort", .json = "sort" },
    .{ .db = "status", .json = "status" },
    .{ .db = "remark", .json = "remark" },
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
    "code",
    "name",
    "sort",
    "status",
    "remark",
    "creator",
    "create_time",
    "updater",
    "update_time",
    "deleted",
    "tenant_id",
};

/// Validate SystemPost data before insert/update.
pub fn validate(data: SystemPost) !void {
    if (data.code.len == 0) return error.ValidationError;
    if (data.name.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
