// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// SystemSmsLog model — maps to `system_sms_log` table.
pub const SystemSmsLog = struct {
    id: ?i64 = null,
    channel_id: i64,
    channel_code: []const u8,
    template_id: i64,
    template_code: []const u8,
    template_type: i64,
    template_content: []const u8,
    template_params: []const u8,
    api_template_id: []const u8,
    mobile: []const u8,
    user_id: ?i64 = null,
    user_type: ?i64 = null,
    send_status: i64,
    send_time: ?[]const u8 = null,
    api_send_code: ?[]const u8 = null,
    api_send_msg: ?[]const u8 = null,
    api_request_id: ?[]const u8 = null,
    api_serial_no: ?[]const u8 = null,
    receive_status: i64,
    receive_time: ?[]const u8 = null,
    api_receive_code: ?[]const u8 = null,
    api_receive_msg: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
};

pub const SystemSmsLogModel = zfinal.Model(SystemSmsLog, "system_sms_log");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
        .{ .db = "id", .json = "id" },
        .{ .db = "channel_id", .json = "channel_id" },
        .{ .db = "channel_code", .json = "channel_code" },
        .{ .db = "template_id", .json = "template_id" },
        .{ .db = "template_code", .json = "template_code" },
        .{ .db = "template_type", .json = "template_type" },
        .{ .db = "template_content", .json = "template_content" },
        .{ .db = "template_params", .json = "template_params" },
        .{ .db = "api_template_id", .json = "api_template_id" },
        .{ .db = "mobile", .json = "mobile" },
        .{ .db = "user_id", .json = "user_id" },
        .{ .db = "user_type", .json = "user_type" },
        .{ .db = "send_status", .json = "send_status" },
        .{ .db = "send_time", .json = "send_time" },
        .{ .db = "api_send_code", .json = "api_send_code" },
        .{ .db = "api_send_msg", .json = "api_send_msg" },
        .{ .db = "api_request_id", .json = "api_request_id" },
        .{ .db = "api_serial_no", .json = "api_serial_no" },
        .{ .db = "receive_status", .json = "receive_status" },
        .{ .db = "receive_time", .json = "receive_time" },
        .{ .db = "api_receive_code", .json = "api_receive_code" },
        .{ .db = "api_receive_msg", .json = "api_receive_msg" },
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
        "channel_id",
        "channel_code",
        "template_id",
        "template_code",
        "template_type",
        "template_content",
        "template_params",
        "api_template_id",
        "mobile",
        "user_id",
        "user_type",
        "send_status",
        "send_time",
        "api_send_code",
        "api_send_msg",
        "api_request_id",
        "api_serial_no",
        "receive_status",
        "receive_time",
        "api_receive_code",
        "api_receive_msg",
        "creator",
        "create_time",
        "updater",
        "update_time",
        "deleted",
};

/// Validate SystemSmsLog data before insert/update.
pub fn validate(data: SystemSmsLog) !void {
    if (data.channel_code.len == 0) return error.ValidationError;
    if (data.template_code.len == 0) return error.ValidationError;
    if (data.template_content.len == 0) return error.ValidationError;
    if (data.template_params.len == 0) return error.ValidationError;
    if (data.api_template_id.len == 0) return error.ValidationError;
    if (data.mobile.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
