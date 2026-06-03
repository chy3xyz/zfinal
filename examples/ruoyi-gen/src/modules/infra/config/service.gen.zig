// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");
const model = @import("model.gen.zig");
const InfraConfigModel = model.InfraConfigModel;
const validate = model.validate;

// Re-export types so handler doesn't need to import model directly.
pub const Data = model.InfraConfig;
pub const Instance = InfraConfigModel.Instance;

/// List all InfraConfig records.
pub fn findAll(db: *zfinal.DB, allocator: std.mem.Allocator) ![]Data {
    return InfraConfigModel.findAll(db, allocator);
}

/// Find one InfraConfig by primary key.
pub fn findById(db: *zfinal.DB, id: i64, allocator: std.mem.Allocator) !?Instance {
    return InfraConfigModel.findById(db, id, allocator);
}

/// Paginated list.
pub fn paginate(db: *zfinal.DB, page: u32, size: u32, allocator: std.mem.Allocator) ![]Instance {
    return InfraConfigModel.paginate(db, page, size, allocator);
}

/// Total row count.
pub fn count(db: *zfinal.DB) !i64 {
    return InfraConfigModel.count(db);
}

/// Create a new InfraConfig record. Validates input, returns instance with .id set.
pub fn create(db: *zfinal.DB, data: Data) !Instance {
    validate(data) catch return error.ValidationError;
    var instance = Instance{ .data = data };
    try instance.save(db);
    return instance;
}

/// Update InfraConfig record by ID. Returns updated instance.
pub fn update(db: *zfinal.DB, id: i64, data: Data) !Instance {
    var item = try InfraConfigModel.findById(db, id, db.allocator) orelse return error.NotFound;
    // AI: copy non-null fields from data into item.data here (ext/service.zig)
    _ = data;
    validate(item.data) catch return error.ValidationError;
    try item.save(db);
    return item;
}

/// Delete InfraConfig record by ID.
pub fn deleteOne(db: *zfinal.DB, id: i64) !void {
    var item = try InfraConfigModel.findById(db, id, db.allocator) orelse return error.NotFound;
    try item.delete(db);
}