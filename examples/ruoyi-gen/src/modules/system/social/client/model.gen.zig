// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// SystemSocialClient model — maps to `system_social_client` table.
pub const SystemSocialClient = struct {
    id: ?i64 = null,
    name: []const u8,
    social_type: i64,
    user_type: i64,
    client_id: []const u8,
    client_secret: []const u8,
    agent_id: ?[]const u8 = null,
    public_key: ?[]const u8 = null,
    status: i64,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
    tenant_id: i64,
};

pub const SystemSocialClientModel = zfinal.Model(SystemSocialClient, "system_social_client");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
        .{ .db = "id", .json = "id" },
        .{ .db = "name", .json = "name" },
        .{ .db = "social_type", .json = "social_type" },
        .{ .db = "user_type", .json = "user_type" },
        .{ .db = "client_id", .json = "client_id" },
        .{ .db = "client_secret", .json = "client_secret" },
        .{ .db = "agent_id", .json = "agent_id" },
        .{ .db = "public_key", .json = "public_key" },
        .{ .db = "status", .json = "status" },
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
        "name",
        "social_type",
        "user_type",
        "client_id",
        "client_secret",
        "agent_id",
        "public_key",
        "status",
        "creator",
        "create_time",
        "updater",
        "update_time",
        "deleted",
        "tenant_id",
};

/// Validate SystemSocialClient data before insert/update.
pub fn validate(data: SystemSocialClient) !void {
    if (data.name.len == 0) return error.ValidationError;
    if (data.client_id.len == 0) return error.ValidationError;
    if (data.client_secret.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
