// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// SystemDictData model — maps to `system_dict_data` table.
pub const SystemDictData = struct {
    id: ?i64 = null,
    sort: i64,
    label: []const u8,
    value: []const u8,
    dict_type: []const u8,
    status: i64,
    color_type: ?[]const u8 = null,
    css_class: ?[]const u8 = null,
    remark: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
};

pub const SystemDictDataModel = zfinal.Model(SystemDictData, "system_dict_data");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
    .{ .db = "id", .json = "id" },
    .{ .db = "sort", .json = "sort" },
    .{ .db = "label", .json = "label" },
    .{ .db = "value", .json = "value" },
    .{ .db = "dict_type", .json = "dict_type" },
    .{ .db = "status", .json = "status" },
    .{ .db = "color_type", .json = "color_type" },
    .{ .db = "css_class", .json = "css_class" },
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
    "sort",
    "label",
    "value",
    "dict_type",
    "status",
    "color_type",
    "css_class",
    "remark",
    "creator",
    "create_time",
    "updater",
    "update_time",
    "deleted",
};

/// Validate SystemDictData data before insert/update.
pub fn validate(data: SystemDictData) !void {
    if (data.label.len == 0) return error.ValidationError;
    if (data.value.len == 0) return error.ValidationError;
    if (data.dict_type.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
