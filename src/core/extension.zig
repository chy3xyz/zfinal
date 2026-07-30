//! Request-scoped typed Extensions (Axum `Extension<T>` analogue).
//! App-wide deps stay in `state.Handle` / `ctx.state(T)`.
const std = @import("std");
const state = @import("state.zig");

const DestroyFn = *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void;

const Entry = struct {
    type_id: usize,
    ptr: *anyopaque,
    destroy: ?DestroyFn,
};

/// Fixed-capacity bag (enough for JWT, request meta, etc.).
pub const Bag = struct {
    entries: [16]?Entry = @splat(null),
    len: usize = 0,

    pub fn deinit(self: *Bag, allocator: std.mem.Allocator) void {
        for (self.entries[0..self.len]) |maybe| {
            if (maybe) |e| {
                if (e.destroy) |d| d(e.ptr, allocator);
            }
        }
        self.* = .{};
    }

    /// Insert or replace. If `destroy` is set, `deinit` / replace will call it with `allocator`.
    pub fn set(self: *Bag, allocator: std.mem.Allocator, comptime T: type, ptr: *T, destroy: ?DestroyFn) !void {
        const tid = state.typeId(T);
        for (self.entries[0..self.len]) |*maybe| {
            if (maybe.*) |*e| {
                if (e.type_id == tid) {
                    if (e.destroy) |d| d(e.ptr, allocator);
                    e.ptr = ptr;
                    e.destroy = destroy;
                    return;
                }
            }
        }
        if (self.len >= self.entries.len) return error.ExtensionBagFull;
        self.entries[self.len] = .{ .type_id = tid, .ptr = ptr, .destroy = destroy };
        self.len += 1;
    }

    pub fn get(self: *const Bag, comptime T: type) ?*T {
        const tid = state.typeId(T);
        for (self.entries[0..self.len]) |maybe| {
            if (maybe) |e| {
                if (e.type_id == tid) return @ptrCast(@alignCast(e.ptr));
            }
        }
        return null;
    }
};

fn destroyTyped(comptime T: type) DestroyFn {
    return struct {
        fn d(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const p: *T = @ptrCast(@alignCast(ptr));
            allocator.destroy(p);
        }
    }.d;
}

/// Allocate `value` on `allocator`, store in bag, free on `Bag.deinit`.
pub fn putOwned(bag: *Bag, allocator: std.mem.Allocator, comptime T: type, value: T) !void {
    const p = try allocator.create(T);
    errdefer allocator.destroy(p);
    p.* = value;
    try bag.set(allocator, T, p, destroyTyped(T));
}

/// Common JWT identity extension (pointers into Context attrs / request lifetime).
pub const JwtIdentity = struct {
    sub: []const u8,
    role: []const u8 = "",
};

/// Typed request id (also mirrored in attrs / header).
pub const RequestId = struct {
    value: []const u8,
};

test "Bag put/get" {
    const a = std.testing.allocator;
    var bag: Bag = .{};
    defer bag.deinit(a);
    try putOwned(&bag, a, JwtIdentity, .{ .sub = "u1", .role = "admin" });
    const got = bag.get(JwtIdentity).?;
    try std.testing.expectEqualStrings("u1", got.sub);
}
