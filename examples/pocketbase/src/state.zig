const std = @import("std");
const zfinal = @import("zfinal");

/// Global state for PocketBase Lite demo
/// This is used to share the database connection across controllers
pub const State = struct {
    db: *zfinal.DB,
    allocator: std.mem.Allocator,
};

/// Get the global state
pub fn getState() ?State {
    return global_state;
}

/// Global state instance
pub var global_state: ?State = null;
