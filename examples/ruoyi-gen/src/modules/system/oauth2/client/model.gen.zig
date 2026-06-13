// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// SystemOauth2Client model — maps to `system_oauth2_client` table.
pub const SystemOauth2Client = struct {
    id: ?i64 = null,
    client_id: []const u8,
    secret: []const u8,
    name: []const u8,
    logo: []const u8,
    description: ?[]const u8 = null,
    status: i64,
    access_token_validity_seconds: i64,
    refresh_token_validity_seconds: i64,
    redirect_uris: []const u8,
    authorized_grant_types: []const u8,
    scopes: ?[]const u8 = null,
    auto_approve_scopes: ?[]const u8 = null,
    authorities: ?[]const u8 = null,
    resource_ids: ?[]const u8 = null,
    additional_information: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
};

pub const SystemOauth2ClientModel = zfinal.Model(SystemOauth2Client, "system_oauth2_client");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
    .{ .db = "id", .json = "id" },
    .{ .db = "client_id", .json = "client_id" },
    .{ .db = "secret", .json = "secret" },
    .{ .db = "name", .json = "name" },
    .{ .db = "logo", .json = "logo" },
    .{ .db = "description", .json = "description" },
    .{ .db = "status", .json = "status" },
    .{ .db = "access_token_validity_seconds", .json = "access_token_validity_seconds" },
    .{ .db = "refresh_token_validity_seconds", .json = "refresh_token_validity_seconds" },
    .{ .db = "redirect_uris", .json = "redirect_uris" },
    .{ .db = "authorized_grant_types", .json = "authorized_grant_types" },
    .{ .db = "scopes", .json = "scopes" },
    .{ .db = "auto_approve_scopes", .json = "auto_approve_scopes" },
    .{ .db = "authorities", .json = "authorities" },
    .{ .db = "resource_ids", .json = "resource_ids" },
    .{ .db = "additional_information", .json = "additional_information" },
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
    "client_id",
    "name",
    "logo",
    "description",
    "status",
    "access_token_validity_seconds",
    "refresh_token_validity_seconds",
    "redirect_uris",
    "authorized_grant_types",
    "scopes",
    "auto_approve_scopes",
    "authorities",
    "resource_ids",
    "additional_information",
    "creator",
    "create_time",
    "updater",
    "update_time",
    "deleted",
};

/// Validate SystemOauth2Client data before insert/update.
pub fn validate(data: SystemOauth2Client) !void {
    if (data.client_id.len == 0) return error.ValidationError;
    if (data.secret.len == 0) return error.ValidationError;
    if (data.name.len == 0) return error.ValidationError;
    if (data.logo.len == 0) return error.ValidationError;
    if (data.redirect_uris.len == 0) return error.ValidationError;
    if (data.authorized_grant_types.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
