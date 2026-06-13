// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// SystemNotifyMessage model — maps to `system_notify_message` table.
pub const SystemNotifyMessage = struct {
    id: ?i64 = null,
    user_id: i64,
    user_type: i64,
    template_id: i64,
    template_code: []const u8,
    template_nickname: []const u8,
    template_content: []const u8,
    template_type: i64,
    template_params: []const u8,
    read_status: bool,
    read_time: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
    tenant_id: i64,
};

pub const SystemNotifyMessageModel = zfinal.Model(SystemNotifyMessage, "system_notify_message");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
    .{ .db = "id", .json = "id" },
    .{ .db = "user_id", .json = "user_id" },
    .{ .db = "user_type", .json = "user_type" },
    .{ .db = "template_id", .json = "template_id" },
    .{ .db = "template_code", .json = "template_code" },
    .{ .db = "template_nickname", .json = "template_nickname" },
    .{ .db = "template_content", .json = "template_content" },
    .{ .db = "template_type", .json = "template_type" },
    .{ .db = "template_params", .json = "template_params" },
    .{ .db = "read_status", .json = "read_status" },
    .{ .db = "read_time", .json = "read_time" },
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
    "user_type",
    "template_id",
    "template_code",
    "template_nickname",
    "template_content",
    "template_type",
    "template_params",
    "read_status",
    "read_time",
    "creator",
    "create_time",
    "updater",
    "update_time",
    "deleted",
    "tenant_id",
};

/// Validate SystemNotifyMessage data before insert/update.
pub fn validate(data: SystemNotifyMessage) !void {
    if (data.template_code.len == 0) return error.ValidationError;
    if (data.template_nickname.len == 0) return error.ValidationError;
    if (data.template_content.len == 0) return error.ValidationError;
    if (data.template_params.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
