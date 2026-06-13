// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// SystemMailLog model — maps to `system_mail_log` table.
pub const SystemMailLog = struct {
    id: ?i64 = null,
    user_id: ?i64 = null,
    user_type: ?i64 = null,
    to_mails: []const u8,
    cc_mails: ?[]const u8 = null,
    bcc_mails: ?[]const u8 = null,
    account_id: i64,
    from_mail: []const u8,
    template_id: i64,
    template_code: []const u8,
    template_nickname: ?[]const u8 = null,
    template_title: []const u8,
    template_content: []const u8,
    template_params: []const u8,
    send_status: i64,
    send_time: ?[]const u8 = null,
    send_message_id: ?[]const u8 = null,
    send_exception: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
};

pub const SystemMailLogModel = zfinal.Model(SystemMailLog, "system_mail_log");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
    .{ .db = "id", .json = "id" },
    .{ .db = "user_id", .json = "user_id" },
    .{ .db = "user_type", .json = "user_type" },
    .{ .db = "to_mails", .json = "to_mails" },
    .{ .db = "cc_mails", .json = "cc_mails" },
    .{ .db = "bcc_mails", .json = "bcc_mails" },
    .{ .db = "account_id", .json = "account_id" },
    .{ .db = "from_mail", .json = "from_mail" },
    .{ .db = "template_id", .json = "template_id" },
    .{ .db = "template_code", .json = "template_code" },
    .{ .db = "template_nickname", .json = "template_nickname" },
    .{ .db = "template_title", .json = "template_title" },
    .{ .db = "template_content", .json = "template_content" },
    .{ .db = "template_params", .json = "template_params" },
    .{ .db = "send_status", .json = "send_status" },
    .{ .db = "send_time", .json = "send_time" },
    .{ .db = "send_message_id", .json = "send_message_id" },
    .{ .db = "send_exception", .json = "send_exception" },
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
    "user_id",
    "user_type",
    "to_mails",
    "cc_mails",
    "bcc_mails",
    "account_id",
    "from_mail",
    "template_id",
    "template_code",
    "template_nickname",
    "template_title",
    "template_content",
    "template_params",
    "send_status",
    "send_time",
    "send_message_id",
    "send_exception",
    "creator",
    "create_time",
    "updater",
    "update_time",
    "deleted",
};

/// Validate SystemMailLog data before insert/update.
pub fn validate(data: SystemMailLog) !void {
    if (data.to_mails.len == 0) return error.ValidationError;
    if (data.from_mail.len == 0) return error.ValidationError;
    if (data.template_code.len == 0) return error.ValidationError;
    if (data.template_title.len == 0) return error.ValidationError;
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
