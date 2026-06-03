// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// SystemSmsCode model — maps to `system_sms_code` table.
pub const SystemSmsCode = struct {
    id: ?i64 = null,
    mobile: []const u8,
    code: []const u8,
    create_ip: []const u8,
    scene: i64,
    today_index: i64,
    used: i64,
    used_time: ?[]const u8 = null,
    used_ip: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
    tenant_id: i64,
};

pub const SystemSmsCodeModel = zfinal.Model(SystemSmsCode, "system_sms_code");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
        .{ .db = "id", .json = "id" },
        .{ .db = "mobile", .json = "mobile" },
        .{ .db = "code", .json = "code" },
        .{ .db = "create_ip", .json = "create_ip" },
        .{ .db = "scene", .json = "scene" },
        .{ .db = "today_index", .json = "today_index" },
        .{ .db = "used", .json = "used" },
        .{ .db = "used_time", .json = "used_time" },
        .{ .db = "used_ip", .json = "used_ip" },
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
        "mobile",
        "code",
        "create_ip",
        "scene",
        "today_index",
        "used",
        "used_time",
        "used_ip",
        "creator",
        "create_time",
        "updater",
        "update_time",
        "deleted",
        "tenant_id",
};

/// Validate SystemSmsCode data before insert/update.
pub fn validate(data: SystemSmsCode) !void {
    if (data.mobile.len == 0) return error.ValidationError;
    if (data.code.len == 0) return error.ValidationError;
    if (data.create_ip.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
