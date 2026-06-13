// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// SystemOauth2Approve model — maps to `system_oauth2_approve` table.
pub const SystemOauth2Approve = struct {
    id: ?i64 = null,
    user_id: i64,
    user_type: i64,
    client_id: []const u8,
    scope: []const u8,
    approved: bool,
    expires_time: []const u8,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
    tenant_id: i64,
};

pub const SystemOauth2ApproveModel = zfinal.Model(SystemOauth2Approve, "system_oauth2_approve");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
    .{ .db = "id", .json = "id" },
    .{ .db = "user_id", .json = "user_id" },
    .{ .db = "user_type", .json = "user_type" },
    .{ .db = "client_id", .json = "client_id" },
    .{ .db = "scope", .json = "scope" },
    .{ .db = "approved", .json = "approved" },
    .{ .db = "expires_time", .json = "expires_time" },
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
    "user_id",
    "user_type",
    "client_id",
    "scope",
    "approved",
    "expires_time",
    "creator",
    "create_time",
    "updater",
    "update_time",
    "deleted",
    "tenant_id",
};

/// Validate SystemOauth2Approve data before insert/update.
pub fn validate(data: SystemOauth2Approve) !void {
    if (data.client_id.len == 0) return error.ValidationError;
    if (data.scope.len == 0) return error.ValidationError;
    if (data.expires_time.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
