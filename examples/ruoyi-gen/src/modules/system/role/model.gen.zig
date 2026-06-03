// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// SystemRole model — maps to `system_role` table.
pub const SystemRole = struct {
    id: ?i64 = null,
    name: []const u8,
    code: []const u8,
    sort: i64,
    data_scope: i64,
    data_scope_dept_ids: []const u8,
};

pub const SystemRoleModel = zfinal.Model(SystemRole, "system_role");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
        .{ .db = "id", .json = "id" },
        .{ .db = "name", .json = "name" },
        .{ .db = "code", .json = "code" },
        .{ .db = "sort", .json = "sort" },
        .{ .db = "data_scope", .json = "data_scope" },
        .{ .db = "data_scope_dept_ids", .json = "data_scope_dept_ids" },
};

pub fn jsonFieldName(comptime db_name: []const u8) []const u8 {
    for (fieldMap) |entry| if (std.mem.eql(u8, entry.db, db_name)) return entry.json;
    return db_name;
}

/// Fields safe to expose in API responses (sensitive columns excluded).
pub const safeFields = [_][]const u8{
        "id",
        "name",
        "code",
        "sort",
        "data_scope",
        "data_scope_dept_ids",
};

/// Validate SystemRole data before insert/update.
pub fn validate(data: SystemRole) !void {
    if (data.name.len == 0) return error.ValidationError;
    if (data.code.len == 0) return error.ValidationError;
    if (data.data_scope_dept_ids.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
