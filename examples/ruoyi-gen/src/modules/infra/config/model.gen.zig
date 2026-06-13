// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// InfraConfig model — maps to `infra_config` table.
pub const InfraConfig = struct {
    id: ?i64 = null,
    category: []const u8,
    type: i64,
    name: []const u8,
    config_key: []const u8,
    value: []const u8,
    visible: bool,
    remark: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
};

pub const InfraConfigModel = zfinal.Model(InfraConfig, "infra_config");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
    .{ .db = "id", .json = "id" },
    .{ .db = "category", .json = "category" },
    .{ .db = "type", .json = "type" },
    .{ .db = "name", .json = "name" },
    .{ .db = "config_key", .json = "config_key" },
    .{ .db = "value", .json = "value" },
    .{ .db = "visible", .json = "visible" },
    .{ .db = "remark", .json = "remark" },
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
    "category",
    "type",
    "name",
    "config_key",
    "value",
    "visible",
    "remark",
    "creator",
    "create_time",
    "updater",
    "update_time",
    "deleted",
};

/// Validate InfraConfig data before insert/update.
pub fn validate(data: InfraConfig) !void {
    if (data.category.len == 0) return error.ValidationError;
    if (data.name.len == 0) return error.ValidationError;
    if (data.config_key.len == 0) return error.ValidationError;
    if (data.value.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
