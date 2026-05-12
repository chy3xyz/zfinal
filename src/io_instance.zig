//! Global Io instance management for Zig 0.16
//! All modules should import this to get access to the global Io instance.
//! In test mode, std.testing.io and std.testing.allocator are used automatically.

const std = @import("std");

/// Global Io instance - uses std.testing.io in test mode, initialized by main() otherwise
pub var io: std.Io = if (@import("builtin").is_test) std.testing.io else undefined;

/// Global allocator - uses std.testing.allocator in test mode, initialized by main() otherwise
pub var allocator: std.mem.Allocator = if (@import("builtin").is_test) std.testing.allocator else undefined;

/// Initialize the global Io and allocator from std.process.Init
pub fn init(init_data: std.process.Init) void {
    io = init_data.io;
    allocator = init_data.gpa;
}
