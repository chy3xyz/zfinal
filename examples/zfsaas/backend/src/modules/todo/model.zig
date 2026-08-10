// @generated — DO NOT EDIT. AI: edit directly.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");

/// Todo model — maps to `todo` table.
pub const Todo = struct {
    id: ?i64 = null,
    owner_id: []const u8,
    org_id: []const u8,
    title: []const u8,
    message: []const u8,
    updated_at: []const u8,
    created_at: []const u8,
};

pub const TodoModel = zfinal.ModelWithPK(Todo, "todo", "id");
pub const jsonNaming: zfinal.JsonNaming = .snake_case;

pub const fieldMap = [_]struct { db: []const u8, json: []const u8 }{
    .{ .db = "id", .json = "id" },
    .{ .db = "owner_id", .json = "owner_id" },
    .{ .db = "org_id", .json = "org_id" },
    .{ .db = "title", .json = "title" },
    .{ .db = "message", .json = "message" },
    .{ .db = "updated_at", .json = "updated_at" },
    .{ .db = "created_at", .json = "created_at" },
};

pub fn jsonFieldName(comptime db_name: []const u8) []const u8 {
    for (fieldMap) |entry| if (std.mem.eql(u8, entry.db, db_name)) return entry.json;
    return db_name;
}

/// Fields safe to expose in API responses (sensitive columns excluded).
pub const safeFields = [_][]const u8{
    "id",
    "owner_id",
    "org_id",
    "title",
    "message",
    "updated_at",
    "created_at",
};

/// Validate Todo data before insert/update.
pub fn validate(data: Todo) !void {
    if (data.owner_id.len == 0) return error.ValidationError;
    if (data.org_id.len == 0) return error.ValidationError;
    if (data.title.len == 0) return error.ValidationError;
    // message / timestamps may be empty — DB defaults or service fills them
    _ = data.message;
    _ = data.updated_at;
    _ = data.created_at;
}

/// Render instance to JSON, excluding sensitive fields.
pub fn renderSafe(ctx: *zfinal.Context, instance: anytype) !void {
    _ = safeFields; // comptime-verified field list
    try ctx.renderJson(instance);
}

// ── ai-edit-zone: model hooks ────────────────────────────────────
// AI: add custom hooks here (e.g. beforeSave, afterLoad). Keep tiny —
// large logic belongs in service.zig.
// ─────────────────────────────────────────────────────────────────
