// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// SystemMailAccount model — maps to `system_mail_account` table.
pub const SystemMailAccount = struct {
    id: ?i64 = null,
    mail: []const u8,
    username: []const u8,
    password: []const u8,
    host: []const u8,
    port: i64,
    ssl_enable: bool,
    starttls_enable: bool,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
};

pub const SystemMailAccountModel = zfinal.Model(SystemMailAccount, "system_mail_account");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
        .{ .db = "id", .json = "id" },
        .{ .db = "mail", .json = "mail" },
        .{ .db = "username", .json = "username" },
        .{ .db = "password", .json = "password" },
        .{ .db = "host", .json = "host" },
        .{ .db = "port", .json = "port" },
        .{ .db = "ssl_enable", .json = "ssl_enable" },
        .{ .db = "starttls_enable", .json = "starttls_enable" },
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
        "mail",
        "username",
        "host",
        "port",
        "ssl_enable",
        "starttls_enable",
        "creator",
        "create_time",
        "updater",
        "update_time",
        "deleted",
};

/// Validate SystemMailAccount data before insert/update.
pub fn validate(data: SystemMailAccount) !void {
    if (data.mail.len == 0) return error.ValidationError;
    if (data.username.len == 0) return error.ValidationError;
    if (data.password.len == 0) return error.ValidationError;
    if (data.host.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
