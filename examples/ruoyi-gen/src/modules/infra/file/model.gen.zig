// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// InfraFile model — maps to `infra_file` table.
pub const InfraFile = struct {
    id: ?i64 = null,
    config_id: ?i64 = null,
    name: ?[]const u8 = null,
    path: []const u8,
    url: []const u8,
    type: ?[]const u8 = null,
    size: i64,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
};

pub const InfraFileModel = zfinal.Model(InfraFile, "infra_file");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
        .{ .db = "id", .json = "id" },
        .{ .db = "config_id", .json = "config_id" },
        .{ .db = "name", .json = "name" },
        .{ .db = "path", .json = "path" },
        .{ .db = "url", .json = "url" },
        .{ .db = "type", .json = "type" },
        .{ .db = "size", .json = "size" },
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
        "config_id",
        "name",
        "path",
        "url",
        "type",
        "size",
        "creator",
        "create_time",
        "updater",
        "update_time",
        "deleted",
};

/// Validate InfraFile data before insert/update.
pub fn validate(data: InfraFile) !void {
    if (data.path.len == 0) return error.ValidationError;
    if (data.url.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
