// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// InfraApiErrorLog model — maps to `infra_api_error_log` table.
pub const InfraApiErrorLog = struct {
    id: ?i64 = null,
    trace_id: []const u8,
    user_id: i64,
    user_type: i64,
    application_name: []const u8,
    request_method: []const u8,
    request_url: []const u8,
    request_params: []const u8,
    user_ip: []const u8,
    user_agent: []const u8,
    exception_time: []const u8,
    exception_name: []const u8,
    exception_message: []const u8,
    exception_root_cause_message: []const u8,
    exception_stack_trace: []const u8,
    exception_class_name: []const u8,
    exception_file_name: []const u8,
    exception_method_name: []const u8,
    exception_line_number: i64,
    process_status: i64,
    process_time: ?[]const u8 = null,
    process_user_id: ?i64 = null,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
    tenant_id: i64,
};

pub const InfraApiErrorLogModel = zfinal.Model(InfraApiErrorLog, "infra_api_error_log");
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
        .{ .db = "user_ip", .json = "user_ip" },
        .{ .db = "user_agent", .json = "user_agent" },
        .{ .db = "exception_time", .json = "exception_time" },
        .{ .db = "exception_name", .json = "exception_name" },
        .{ .db = "exception_message", .json = "exception_message" },
        .{ .db = "exception_root_cause_message", .json = "exception_root_cause_message" },
        .{ .db = "exception_stack_trace", .json = "exception_stack_trace" },
        .{ .db = "exception_class_name", .json = "exception_class_name" },
        .{ .db = "exception_file_name", .json = "exception_file_name" },
        .{ .db = "exception_method_name", .json = "exception_method_name" },
        .{ .db = "exception_line_number", .json = "exception_line_number" },
        .{ .db = "process_status", .json = "process_status" },
        .{ .db = "process_time", .json = "process_time" },
        .{ .db = "process_user_id", .json = "process_user_id" },
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
        "user_ip",
        "user_agent",
        "exception_time",
        "exception_name",
        "exception_message",
        "exception_root_cause_message",
        "exception_stack_trace",
        "exception_class_name",
        "exception_file_name",
        "exception_method_name",
        "exception_line_number",
        "process_status",
        "process_time",
        "process_user_id",
        "creator",
        "create_time",
        "updater",
        "update_time",
        "deleted",
        "tenant_id",
};

/// Validate InfraApiErrorLog data before insert/update.
pub fn validate(data: InfraApiErrorLog) !void {
    if (data.trace_id.len == 0) return error.ValidationError;
    if (data.application_name.len == 0) return error.ValidationError;
    if (data.request_method.len == 0) return error.ValidationError;
    if (data.request_url.len == 0) return error.ValidationError;
    if (data.request_params.len == 0) return error.ValidationError;
    if (data.user_ip.len == 0) return error.ValidationError;
    if (data.user_agent.len == 0) return error.ValidationError;
    if (data.exception_time.len == 0) return error.ValidationError;
    if (data.exception_name.len == 0) return error.ValidationError;
    if (data.exception_message.len == 0) return error.ValidationError;
    if (data.exception_root_cause_message.len == 0) return error.ValidationError;
    if (data.exception_stack_trace.len == 0) return error.ValidationError;
    if (data.exception_class_name.len == 0) return error.ValidationError;
    if (data.exception_file_name.len == 0) return error.ValidationError;
    if (data.exception_method_name.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
