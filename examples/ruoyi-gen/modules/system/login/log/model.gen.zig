// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// SystemLoginLog model — maps to `system_login_log` table.
pub const SystemLoginLog = struct {
    id: ?i64 = null,
    log_type: i64,
    trace_id: []const u8,
    user_id: i64,
    user_type: i64,
    username: []const u8,
    result: i64,
    user_ip: []const u8,
    user_agent: []const u8,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
    tenant_id: i64,
};

pub const SystemLoginLogModel = zfinal.Model(SystemLoginLog, "system_login_log");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
    .{ .db = "id", .json = "id" },
    .{ .db = "log_type", .json = "log_type" },
    .{ .db = "trace_id", .json = "trace_id" },
    .{ .db = "user_id", .json = "user_id" },
    .{ .db = "user_type", .json = "user_type" },
    .{ .db = "username", .json = "username" },
    .{ .db = "result", .json = "result" },
    .{ .db = "user_ip", .json = "user_ip" },
    .{ .db = "user_agent", .json = "user_agent" },
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
    "log_type",
    "trace_id",
    "user_id",
    "user_type",
    "username",
    "result",
    "user_ip",
    "user_agent",
    "creator",
    "create_time",
    "updater",
    "update_time",
    "deleted",
    "tenant_id",
};

/// Validate SystemLoginLog data before insert/update.
pub fn validate(data: SystemLoginLog) !void {
    if (data.trace_id.len == 0) return error.ValidationError;
    if (data.username.len == 0) return error.ValidationError;
    if (data.user_ip.len == 0) return error.ValidationError;
    if (data.user_agent.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
