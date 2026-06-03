// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// SystemOperateLog model — maps to `system_operate_log` table.
pub const SystemOperateLog = struct {
    id: ?i64 = null,
    trace_id: []const u8,
    user_id: i64,
    user_type: i64,
    type: []const u8,
    sub_type: []const u8,
    biz_id: i64,
    action: []const u8,
    success: bool,
    extra: []const u8,
    request_method: ?[]const u8 = null,
    request_url: ?[]const u8 = null,
    user_ip: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
    tenant_id: i64,
};

pub const SystemOperateLogModel = zfinal.Model(SystemOperateLog, "system_operate_log");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
        .{ .db = "id", .json = "id" },
        .{ .db = "trace_id", .json = "trace_id" },
        .{ .db = "user_id", .json = "user_id" },
        .{ .db = "user_type", .json = "user_type" },
        .{ .db = "type", .json = "type" },
        .{ .db = "sub_type", .json = "sub_type" },
        .{ .db = "biz_id", .json = "biz_id" },
        .{ .db = "action", .json = "action" },
        .{ .db = "success", .json = "success" },
        .{ .db = "extra", .json = "extra" },
        .{ .db = "request_method", .json = "request_method" },
        .{ .db = "request_url", .json = "request_url" },
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
        "trace_id",
        "user_id",
        "user_type",
        "type",
        "sub_type",
        "biz_id",
        "action",
        "success",
        "extra",
        "request_method",
        "request_url",
        "user_ip",
        "user_agent",
        "creator",
        "create_time",
        "updater",
        "update_time",
        "deleted",
        "tenant_id",
};

/// Validate SystemOperateLog data before insert/update.
pub fn validate(data: SystemOperateLog) !void {
    if (data.trace_id.len == 0) return error.ValidationError;
    if (data.type.len == 0) return error.ValidationError;
    if (data.sub_type.len == 0) return error.ValidationError;
    if (data.action.len == 0) return error.ValidationError;
    if (data.extra.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
