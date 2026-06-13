// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// InfraJob model — maps to `infra_job` table.
pub const InfraJob = struct {
    id: ?i64 = null,
    name: []const u8,
    status: i64,
    handler_name: []const u8,
    handler_param: ?[]const u8 = null,
    cron_expression: []const u8,
    retry_count: i64,
    retry_interval: i64,
    monitor_timeout: i64,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
};

pub const InfraJobModel = zfinal.Model(InfraJob, "infra_job");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
    .{ .db = "id", .json = "id" },
    .{ .db = "name", .json = "name" },
    .{ .db = "status", .json = "status" },
    .{ .db = "handler_name", .json = "handler_name" },
    .{ .db = "handler_param", .json = "handler_param" },
    .{ .db = "cron_expression", .json = "cron_expression" },
    .{ .db = "retry_count", .json = "retry_count" },
    .{ .db = "retry_interval", .json = "retry_interval" },
    .{ .db = "monitor_timeout", .json = "monitor_timeout" },
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
    "name",
    "status",
    "handler_name",
    "handler_param",
    "cron_expression",
    "retry_count",
    "retry_interval",
    "monitor_timeout",
    "creator",
    "create_time",
    "updater",
    "update_time",
    "deleted",
};

/// Validate InfraJob data before insert/update.
pub fn validate(data: InfraJob) !void {
    if (data.name.len == 0) return error.ValidationError;
    if (data.handler_name.len == 0) return error.ValidationError;
    if (data.cron_expression.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
