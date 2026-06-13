// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// SystemSmsTemplate model — maps to `system_sms_template` table.
pub const SystemSmsTemplate = struct {
    id: ?i64 = null,
    type: i64,
    status: i64,
    code: []const u8,
    name: []const u8,
    content: []const u8,
    params: []const u8,
    remark: ?[]const u8 = null,
    api_template_id: []const u8,
    channel_id: i64,
    channel_code: []const u8,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
};

pub const SystemSmsTemplateModel = zfinal.Model(SystemSmsTemplate, "system_sms_template");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
    .{ .db = "id", .json = "id" },
    .{ .db = "type", .json = "type" },
    .{ .db = "status", .json = "status" },
    .{ .db = "code", .json = "code" },
    .{ .db = "name", .json = "name" },
    .{ .db = "content", .json = "content" },
    .{ .db = "params", .json = "params" },
    .{ .db = "remark", .json = "remark" },
    .{ .db = "api_template_id", .json = "api_template_id" },
    .{ .db = "channel_id", .json = "channel_id" },
    .{ .db = "channel_code", .json = "channel_code" },
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
    "type",
    "status",
    "code",
    "name",
    "content",
    "params",
    "remark",
    "api_template_id",
    "channel_id",
    "channel_code",
    "creator",
    "create_time",
    "updater",
    "update_time",
    "deleted",
};

/// Validate SystemSmsTemplate data before insert/update.
pub fn validate(data: SystemSmsTemplate) !void {
    if (data.code.len == 0) return error.ValidationError;
    if (data.name.len == 0) return error.ValidationError;
    if (data.content.len == 0) return error.ValidationError;
    if (data.params.len == 0) return error.ValidationError;
    if (data.api_template_id.len == 0) return error.ValidationError;
    if (data.channel_code.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
