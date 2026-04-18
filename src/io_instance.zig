//! Global Io instance management for Zig 0.16
//! All modules should import this to get access to the global Io instance.

const std = @import("std");

/// Global Io instance initialized in main()
pub var io: std.Io = undefined;

/// Global allocator initialized in main()
pub var allocator: std.mem.Allocator = undefined;

/// Initialize the global Io and allocator from std.process.Init
pub fn init(init_data: std.process.Init) void {
    io = init_data.io;
    allocator = init_data.gpa;
}
