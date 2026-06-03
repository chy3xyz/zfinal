// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");
const model = @import("model.gen.zig");
const SystemOauth2ApproveModel = model.SystemOauth2ApproveModel;
const validate = model.validate;

// Re-export types so handler doesn't need to import model directly.
pub const Data = model.SystemOauth2Approve;
pub const Instance = SystemOauth2ApproveModel.Instance;

/// List all SystemOauth2Approve records.
pub fn findAll(db: *zfinal.DB, allocator: std.mem.Allocator) ![]Data {
    return SystemOauth2ApproveModel.findAll(db, allocator);
}

/// Find one SystemOauth2Approve by primary key.
pub fn findById(db: *zfinal.DB, id: i64, allocator: std.mem.Allocator) !?Instance {
    return SystemOauth2ApproveModel.findById(db, id, allocator);
}

/// Paginated list.
pub fn paginate(db: *zfinal.DB, page: u32, size: u32, allocator: std.mem.Allocator) ![]Instance {
    return SystemOauth2ApproveModel.paginate(db, page, size, allocator);
}

/// Total row count.
pub fn count(db: *zfinal.DB) !i64 {
    return SystemOauth2ApproveModel.count(db);
}

/// Create a new SystemOauth2Approve record. Validates input, returns instance with .id set.
pub fn create(db: *zfinal.DB, data: Data) !Instance {
    validate(data) catch return error.ValidationError;
    var instance = Instance{ .data = data };
    try instance.save(db);
    return instance;
}

/// Update SystemOauth2Approve record by ID. Returns updated instance.
pub fn update(db: *zfinal.DB, id: i64, data: Data) !Instance {
    var item = try SystemOauth2ApproveModel.findById(db, id, db.allocator) orelse return error.NotFound;
    // AI: copy non-null fields from data into item.data here (ext/service.zig)
    _ = data;
    validate(item.data) catch return error.ValidationError;
    try item.save(db);
    return item;
}

/// Delete SystemOauth2Approve record by ID.
pub fn deleteOne(db: *zfinal.DB, id: i64) !void {
    var item = try SystemOauth2ApproveModel.findById(db, id, db.allocator) orelse return error.NotFound;
    try item.delete(db);
}