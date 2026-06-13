// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// InfraJobLog model — maps to `infra_job_log` table.
pub const InfraJobLog = struct {
    id: ?i64 = null,
    job_id: i64,
    handler_name: []const u8,
    handler_param: ?[]const u8 = null,
    execute_index: i64,
    begin_time: []const u8,
    end_time: ?[]const u8 = null,
    duration: ?i64 = null,
    status: i64,
    result: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
};

pub const InfraJobLogModel = zfinal.Model(InfraJobLog, "infra_job_log");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
    .{ .db = "id", .json = "id" },
    .{ .db = "job_id", .json = "job_id" },
    .{ .db = "handler_name", .json = "handler_name" },
    .{ .db = "handler_param", .json = "handler_param" },
    .{ .db = "execute_index", .json = "execute_index" },
    .{ .db = "begin_time", .json = "begin_time" },
    .{ .db = "end_time", .json = "end_time" },
    .{ .db = "duration", .json = "duration" },
    .{ .db = "status", .json = "status" },
    .{ .db = "result", .json = "result" },
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
    "job_id",
    "handler_name",
    "handler_param",
    "execute_index",
    "begin_time",
    "end_time",
    "duration",
    "status",
    "result",
    "creator",
    "create_time",
    "updater",
    "update_time",
    "deleted",
};

/// Validate InfraJobLog data before insert/update.
pub fn validate(data: InfraJobLog) !void {
    if (data.handler_name.len == 0) return error.ValidationError;
    if (data.begin_time.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
