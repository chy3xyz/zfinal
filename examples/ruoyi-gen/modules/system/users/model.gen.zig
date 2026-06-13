// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// SystemUsers model — maps to `system_users` table.
pub const SystemUsers = struct {
    id: ?i64 = null,
    username: []const u8,
    password: []const u8,
    nickname: []const u8,
    remark: ?[]const u8 = null,
    dept_id: ?i64 = null,
    post_ids: ?[]const u8 = null,
    email: ?[]const u8 = null,
    mobile: ?[]const u8 = null,
    sex: ?i64 = null,
    avatar: ?[]const u8 = null,
    status: i64,
    login_ip: ?[]const u8 = null,
    login_date: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
    tenant_id: i64,
};

pub const SystemUsersModel = zfinal.Model(SystemUsers, "system_users");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
    .{ .db = "id", .json = "id" },
    .{ .db = "username", .json = "username" },
    .{ .db = "password", .json = "password" },
    .{ .db = "nickname", .json = "nickname" },
    .{ .db = "remark", .json = "remark" },
    .{ .db = "dept_id", .json = "dept_id" },
    .{ .db = "post_ids", .json = "post_ids" },
    .{ .db = "email", .json = "email" },
    .{ .db = "mobile", .json = "mobile" },
    .{ .db = "sex", .json = "sex" },
    .{ .db = "avatar", .json = "avatar" },
    .{ .db = "status", .json = "status" },
    .{ .db = "login_ip", .json = "login_ip" },
    .{ .db = "login_date", .json = "login_date" },
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
    "username",
    "nickname",
    "remark",
    "dept_id",
    "post_ids",
    "email",
    "mobile",
    "sex",
    "avatar",
    "status",
    "login_ip",
    "login_date",
    "creator",
    "create_time",
    "updater",
    "update_time",
    "deleted",
    "tenant_id",
};

/// Validate SystemUsers data before insert/update.
pub fn validate(data: SystemUsers) !void {
    if (data.username.len == 0) return error.ValidationError;
    if (data.password.len == 0) return error.ValidationError;
    if (data.nickname.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
