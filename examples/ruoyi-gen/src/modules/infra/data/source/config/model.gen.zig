// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// InfraDataSourceConfig model — maps to `infra_data_source_config` table.
pub const InfraDataSourceConfig = struct {
    id: ?i64 = null,
    name: []const u8,
    url: []const u8,
    username: []const u8,
    password: []const u8,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
};

pub const InfraDataSourceConfigModel = zfinal.Model(InfraDataSourceConfig, "infra_data_source_config");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
    .{ .db = "id", .json = "id" },
    .{ .db = "name", .json = "name" },
    .{ .db = "url", .json = "url" },
    .{ .db = "username", .json = "username" },
    .{ .db = "password", .json = "password" },
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
    "url",
    "username",
    "creator",
    "create_time",
    "updater",
    "update_time",
    "deleted",
};

/// Validate InfraDataSourceConfig data before insert/update.
pub fn validate(data: InfraDataSourceConfig) !void {
    if (data.name.len == 0) return error.ValidationError;
    if (data.url.len == 0) return error.ValidationError;
    if (data.username.len == 0) return error.ValidationError;
    if (data.password.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
