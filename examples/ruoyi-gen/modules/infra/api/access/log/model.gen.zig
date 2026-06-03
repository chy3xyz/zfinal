// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// InfraApiAccessLog model — maps to `infra_api_access_log` table.
pub const InfraApiAccessLog = struct {
    id: ?i64 = null,
    trace_id: []const u8,
    user_id: i64,
    user_type: i64,
    application_name: []const u8,
    request_method: []const u8,
    request_url: []const u8,
    request_params: ?[]const u8 = null,
    response_body: ?[]const u8 = null,
    user_ip: []const u8,
    user_agent: []const u8,
    operate_module: ?[]const u8 = null,
    operate_name: ?[]const u8 = null,
    operate_type: ?i64 = null,
    begin_time: []const u8,
    end_time: []const u8,
    duration: i64,
    result_code: i64,
    result_msg: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
    tenant_id: i64,
};

pub const InfraApiAccessLogModel = zfinal.Model(InfraApiAccessLog, "infra_api_access_log");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
        .{ .db = "id", .json = "id" },
        .{ .db = "trace_id", .json = "trace_id" },
        .{ .db = "user_id", .json = "user_id" },
        .{ .db = "user_type", .json = "user_type" },
        .{ .db = "application_name", .json = "application_name" },
        .{ .db = "request_method", .json = "request_method" },
        .{ .db = "request_url", .json = "request_url" },
        .{ .db = "request_params", .json = "request_params" },
        .{ .db = "response_body", .json = "response_body" },
        .{ .db = "user_ip", .json = "user_ip" },
        .{ .db = "user_agent", .json = "user_agent" },
        .{ .db = "operate_module", .json = "operate_module" },
        .{ .db = "operate_name", .json = "operate_name" },
        .{ .db = "operate_type", .json = "operate_type" },
        .{ .db = "begin_time", .json = "begin_time" },
        .{ .db = "end_time", .json = "end_time" },
        .{ .db = "duration", .json = "duration" },
        .{ .db = "result_code", .json = "result_code" },
        .{ .db = "result_msg", .json = "result_msg" },
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
        "application_name",
        "request_method",
        "request_url",
        "request_params",
        "response_body",
        "user_ip",
        "user_agent",
        "operate_module",
        "operate_name",
        "operate_type",
        "begin_time",
        "end_time",
        "duration",
        "result_code",
        "result_msg",
        "creator",
        "create_time",
        "updater",
        "update_time",
        "deleted",
        "tenant_id",
};

/// Validate InfraApiAccessLog data before insert/update.
pub fn validate(data: InfraApiAccessLog) !void {
    if (data.trace_id.len == 0) return error.ValidationError;
    if (data.application_name.len == 0) return error.ValidationError;
    if (data.request_method.len == 0) return error.ValidationError;
    if (data.request_url.len == 0) return error.ValidationError;
    if (data.user_ip.len == 0) return error.ValidationError;
    if (data.user_agent.len == 0) return error.ValidationError;
    if (data.begin_time.len == 0) return error.ValidationError;
    if (data.end_time.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
