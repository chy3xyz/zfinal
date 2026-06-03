// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");
const model = @import("model.gen.zig");
const SystemSmsCodeModel = model.SystemSmsCodeModel;
const validate = model.validate;

// Re-export types so handler doesn't need to import model directly.
pub const Data = model.SystemSmsCode;
pub const Instance = SystemSmsCodeModel.Instance;

/// List all SystemSmsCode records.
pub fn findAll(db: *zfinal.DB, allocator: std.mem.Allocator) ![]Data {
    return SystemSmsCodeModel.findAll(db, allocator);
}

/// Find one SystemSmsCode by primary key.
pub fn findById(db: *zfinal.DB, id: i64, allocator: std.mem.Allocator) !?Instance {
    return SystemSmsCodeModel.findById(db, id, allocator);
}

/// Paginated list.
pub fn paginate(db: *zfinal.DB, page: u32, size: u32, allocator: std.mem.Allocator) ![]Instance {
    return SystemSmsCodeModel.paginate(db, page, size, allocator);
}

/// Total row count.
pub fn count(db: *zfinal.DB) !i64 {
    return SystemSmsCodeModel.count(db);
}

/// Create a new SystemSmsCode record. Validates input, returns instance with .id set.
pub fn create(db: *zfinal.DB, data: Data) !Instance {
    validate(data) catch return error.ValidationError;
    var instance = Instance{ .data = data };
    try instance.save(db);
    return instance;
}

/// Update SystemSmsCode record by ID. Returns updated instance.
pub fn update(db: *zfinal.DB, id: i64, data: Data) !Instance {
    var item = try SystemSmsCodeModel.findById(db, id, db.allocator) orelse return error.NotFound;
    // AI: copy non-null fields from data into item.data here (ext/service.zig)
    _ = data;
    validate(item.data) catch return error.ValidationError;
    try item.save(db);
    return item;
}

/// Delete SystemSmsCode record by ID.
pub fn deleteOne(db: *zfinal.DB, id: i64) !void {
    var item = try SystemSmsCodeModel.findById(db, id, db.allocator) orelse return error.NotFound;
    try item.delete(db);
}