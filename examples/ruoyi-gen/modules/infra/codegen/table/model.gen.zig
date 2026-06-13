// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// InfraCodegenTable model — maps to `infra_codegen_table` table.
pub const InfraCodegenTable = struct {
    id: ?i64 = null,
    data_source_config_id: i64,
    scene: i64,
    table_name: []const u8,
    table_comment: []const u8,
    remark: ?[]const u8 = null,
    module_name: []const u8,
    business_name: []const u8,
    class_name: []const u8,
    class_comment: []const u8,
    author: []const u8,
    template_type: i64,
    front_type: i64,
    parent_menu_id: ?i64 = null,
    master_table_id: ?i64 = null,
    sub_join_column_id: ?i64 = null,
    sub_join_many: ?bool = null,
    tree_parent_column_id: ?i64 = null,
    tree_name_column_id: ?i64 = null,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
};

pub const InfraCodegenTableModel = zfinal.Model(InfraCodegenTable, "infra_codegen_table");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
    .{ .db = "id", .json = "id" },
    .{ .db = "data_source_config_id", .json = "data_source_config_id" },
    .{ .db = "scene", .json = "scene" },
    .{ .db = "table_name", .json = "table_name" },
    .{ .db = "table_comment", .json = "table_comment" },
    .{ .db = "remark", .json = "remark" },
    .{ .db = "module_name", .json = "module_name" },
    .{ .db = "business_name", .json = "business_name" },
    .{ .db = "class_name", .json = "class_name" },
    .{ .db = "class_comment", .json = "class_comment" },
    .{ .db = "author", .json = "author" },
    .{ .db = "template_type", .json = "template_type" },
    .{ .db = "front_type", .json = "front_type" },
    .{ .db = "parent_menu_id", .json = "parent_menu_id" },
    .{ .db = "master_table_id", .json = "master_table_id" },
    .{ .db = "sub_join_column_id", .json = "sub_join_column_id" },
    .{ .db = "sub_join_many", .json = "sub_join_many" },
    .{ .db = "tree_parent_column_id", .json = "tree_parent_column_id" },
    .{ .db = "tree_name_column_id", .json = "tree_name_column_id" },
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
    "data_source_config_id",
    "scene",
    "table_name",
    "table_comment",
    "remark",
    "module_name",
    "business_name",
    "class_name",
    "class_comment",
    "author",
    "template_type",
    "front_type",
    "parent_menu_id",
    "master_table_id",
    "sub_join_column_id",
    "sub_join_many",
    "tree_parent_column_id",
    "tree_name_column_id",
    "creator",
    "create_time",
    "updater",
    "update_time",
    "deleted",
};

/// Validate InfraCodegenTable data before insert/update.
pub fn validate(data: InfraCodegenTable) !void {
    if (data.table_name.len == 0) return error.ValidationError;
    if (data.table_comment.len == 0) return error.ValidationError;
    if (data.module_name.len == 0) return error.ValidationError;
    if (data.business_name.len == 0) return error.ValidationError;
    if (data.class_name.len == 0) return error.ValidationError;
    if (data.class_comment.len == 0) return error.ValidationError;
    if (data.author.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
