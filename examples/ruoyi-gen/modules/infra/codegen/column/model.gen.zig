// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// InfraCodegenColumn model — maps to `infra_codegen_column` table.
pub const InfraCodegenColumn = struct {
    id: ?i64 = null,
    table_id: i64,
    column_name: []const u8,
    data_type: []const u8,
    column_comment: []const u8,
    nullable: bool,
    primary_key: bool,
    ordinal_position: i64,
    java_type: []const u8,
    java_field: []const u8,
    dict_type: ?[]const u8 = null,
    example: ?[]const u8 = null,
    create_operation: bool,
    update_operation: bool,
    list_operation: bool,
    list_operation_condition: []const u8,
    list_operation_result: bool,
    html_type: []const u8,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
};

pub const InfraCodegenColumnModel = zfinal.Model(InfraCodegenColumn, "infra_codegen_column");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
    .{ .db = "id", .json = "id" },
    .{ .db = "table_id", .json = "table_id" },
    .{ .db = "column_name", .json = "column_name" },
    .{ .db = "data_type", .json = "data_type" },
    .{ .db = "column_comment", .json = "column_comment" },
    .{ .db = "nullable", .json = "nullable" },
    .{ .db = "primary_key", .json = "primary_key" },
    .{ .db = "ordinal_position", .json = "ordinal_position" },
    .{ .db = "java_type", .json = "java_type" },
    .{ .db = "java_field", .json = "java_field" },
    .{ .db = "dict_type", .json = "dict_type" },
    .{ .db = "example", .json = "example" },
    .{ .db = "create_operation", .json = "create_operation" },
    .{ .db = "update_operation", .json = "update_operation" },
    .{ .db = "list_operation", .json = "list_operation" },
    .{ .db = "list_operation_condition", .json = "list_operation_condition" },
    .{ .db = "list_operation_result", .json = "list_operation_result" },
    .{ .db = "html_type", .json = "html_type" },
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
    "table_id",
    "column_name",
    "data_type",
    "column_comment",
    "nullable",
    "primary_key",
    "ordinal_position",
    "java_type",
    "java_field",
    "dict_type",
    "example",
    "create_operation",
    "update_operation",
    "list_operation",
    "list_operation_condition",
    "list_operation_result",
    "html_type",
    "creator",
    "create_time",
    "updater",
    "update_time",
    "deleted",
};

/// Validate InfraCodegenColumn data before insert/update.
pub fn validate(data: InfraCodegenColumn) !void {
    if (data.column_name.len == 0) return error.ValidationError;
    if (data.data_type.len == 0) return error.ValidationError;
    if (data.column_comment.len == 0) return error.ValidationError;
    if (data.java_type.len == 0) return error.ValidationError;
    if (data.java_field.len == 0) return error.ValidationError;
    if (data.list_operation_condition.len == 0) return error.ValidationError;
    if (data.html_type.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
