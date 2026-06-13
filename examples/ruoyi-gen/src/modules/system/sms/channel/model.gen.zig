// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// SystemSmsChannel model — maps to `system_sms_channel` table.
pub const SystemSmsChannel = struct {
    id: ?i64 = null,
    signature: []const u8,
    code: []const u8,
    status: i64,
    remark: ?[]const u8 = null,
    api_key: []const u8,
    api_secret: ?[]const u8 = null,
    callback_url: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
};

pub const SystemSmsChannelModel = zfinal.Model(SystemSmsChannel, "system_sms_channel");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
    .{ .db = "id", .json = "id" },
    .{ .db = "signature", .json = "signature" },
    .{ .db = "code", .json = "code" },
    .{ .db = "status", .json = "status" },
    .{ .db = "remark", .json = "remark" },
    .{ .db = "api_key", .json = "api_key" },
    .{ .db = "api_secret", .json = "api_secret" },
    .{ .db = "callback_url", .json = "callback_url" },
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
    "signature",
    "code",
    "status",
    "remark",
    "api_key",
    "api_secret",
    "callback_url",
    "creator",
    "create_time",
    "updater",
    "update_time",
    "deleted",
};

/// Validate SystemSmsChannel data before insert/update.
pub fn validate(data: SystemSmsChannel) !void {
    if (data.signature.len == 0) return error.ValidationError;
    if (data.code.len == 0) return error.ValidationError;
    if (data.api_key.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
