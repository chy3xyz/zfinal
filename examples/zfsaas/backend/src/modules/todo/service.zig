//! Todo service — org-scoped CRUD (zf model + custom predicates).
const std = @import("std");
const zfinal = @import("zfinal");
const model = @import("model.zig");
const TodoModel = model.TodoModel;
const validate = model.validate;

pub const Data = model.Todo;
pub const Instance = TodoModel.Instance;

pub fn listByOrg(db: *zfinal.DB, allocator: std.mem.Allocator, org_id: []const u8, q: ?[]const u8) ![]Instance {
    var query = TodoModel.Query.init(db, allocator);
    defer query.deinit();
    try query.textEq("org_id", org_id);
    try query.likeAll(&.{ "title", "message" }, q);
    try query.orderBy("id", .desc);
    return query.list(allocator);
}

/// Paginated org-scoped list (P1). Page is 1-based; size clamped by caller.
pub fn paginateByOrg(db: *zfinal.DB, allocator: std.mem.Allocator, org_id: []const u8, q: ?[]const u8, page: usize, size: usize) !zfinal.Page(Instance) {
    var query = TodoModel.Query.init(db, allocator);
    defer query.deinit();
    try query.textEq("org_id", org_id);
    try query.likeAll(&.{ "title", "message" }, q);
    try query.orderBy("id", .desc);
    return query.paginate(page, size, allocator);
}

pub fn findByIdInOrg(db: *zfinal.DB, allocator: std.mem.Allocator, id: i64, org_id: []const u8) !?Instance {
    var rs = try db.queryParams(
        "SELECT id FROM todo WHERE id = ? AND org_id = ?",
        &.{ .{ .int = id }, .{ .text = org_id } },
    );
    defer rs.deinit();
    if (!rs.next()) return null;
    return TodoModel.findById(db, id, allocator);
}

pub fn createInOrg(db: *zfinal.DB, title: []const u8, message: []const u8, org_id: []const u8, owner_id: []const u8) !Instance {
    const ts = "1970-01-01T00:00:00Z";
    var instance = Instance{ .data = .{
        .owner_id = owner_id,
        .org_id = org_id,
        .title = title,
        .message = message,
        .updated_at = ts,
        .created_at = ts,
    } };
    validate(instance.data) catch return error.ValidationError;
    try instance.save(db);
    return instance;
}

pub fn updateInOrg(db: *zfinal.DB, allocator: std.mem.Allocator, id: i64, org_id: []const u8, title: ?[]const u8, message: ?[]const u8) !Instance {
    var item = try findByIdInOrg(db, allocator, id, org_id) orelse return error.NotFound;
    if (title) |t| {
        if (t.len > 0) item.data.title = t;
    }
    if (message) |m| item.data.message = m;
    try item.save(db);
    return item;
}

pub fn deleteInOrg(db: *zfinal.DB, allocator: std.mem.Allocator, id: i64, org_id: []const u8) !void {
    var item = try findByIdInOrg(db, allocator, id, org_id) orelse return error.NotFound;
    try item.delete(db);
}

// ── ai-edit-zone: business rules ─────────────────────────────────
// Org-scoped helpers above are the SaaS Kit premium surface.
// ─────────────────────────────────────────────────────────────────
