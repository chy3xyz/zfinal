const std = @import("std");
const zfinal = @import("zfinal");
const gen = @import("../service.gen.zig");

pub const findAll = gen.findAll;
pub const findById = gen.findById;
pub const paginate = gen.paginate;
pub const count = gen.count;
pub const create = gen.create;
pub const update = gen.update;
pub const deleteOne = gen.deleteOne;

// ── Custom business logic ──
// Add your cross-model operations, transactions, complex validation below.
