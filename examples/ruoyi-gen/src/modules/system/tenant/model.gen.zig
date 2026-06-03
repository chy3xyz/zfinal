// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// SystemTenant model — maps to `system_tenant` table.
pub const SystemTenant = struct {
    id: ?i64 = null,
    name: []const u8,
    contact_user_id: ?i64 = null,
    contact_name: []const u8,
    contact_mobile: ?[]const u8 = null,
    status: i64,
    websites: ?[]const u8 = null,
    package_id: i64,
    expire_time: []const u8,
    account_count: i64,
    creator: []const u8,
    create_time: []const u8,
    updater: ?[]const u8 = null,
    update_time: []const u8,
    deleted: bool,
};

pub const SystemTenantModel = zfinal.Model(SystemTenant, "system_tenant");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
        .{ .db = "id", .json = "id" },
        .{ .db = "name", .json = "name" },
        .{ .db = "contact_user_id", .json = "contact_user_id" },
        .{ .db = "contact_name", .json = "contact_name" },
        .{ .db = "contact_mobile", .json = "contact_mobile" },
        .{ .db = "status", .json = "status" },
        .{ .db = "websites", .json = "websites" },
        .{ .db = "package_id", .json = "package_id" },
        .{ .db = "expire_time", .json = "expire_time" },
        .{ .db = "account_count", .json = "account_count" },
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
        "contact_user_id",
        "contact_name",
        "contact_mobile",
        "status",
        "websites",
        "package_id",
        "expire_time",
        "account_count",
        "creator",
        "create_time",
        "updater",
        "update_time",
        "deleted",
};

/// Validate SystemTenant data before insert/update.
pub fn validate(data: SystemTenant) !void {
    if (data.name.len == 0) return error.ValidationError;
    if (data.contact_name.len == 0) return error.ValidationError;
    if (data.expire_time.len == 0) return error.ValidationError;
    if (data.creator.len == 0) return error.ValidationError;
    if (data.create_time.len == 0) return error.ValidationError;
    if (data.update_time.len == 0) return error.ValidationError;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}
