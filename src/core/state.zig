//! App-level typed State (Axum `State<T>` analogue).
//! `app.setState(T, &value)` → `ctx.state(T)` in handlers/interceptors.
const std = @import("std");

/// Unique id per type (address of a type-local static).
pub fn typeId(comptime T: type) usize {
    const Marker = struct {
        var id: u8 = 0;
        comptime {
            _ = T;
        }
    };
    return @intFromPtr(&Marker.id);
}

/// Erased state handle carried by ZFinal → Server → Context.
pub const Handle = struct {
    ptr: ?*anyopaque = null,
    type_id: usize = 0,

    pub fn set(self: *Handle, comptime T: type, value: *T) void {
        self.ptr = value;
        self.type_id = typeId(T);
    }

    pub fn clear(self: *Handle) void {
        self.* = .{};
    }

    pub fn get(self: Handle, comptime T: type) !*T {
        if (self.ptr == null) return error.StateNotSet;
        if (self.type_id != typeId(T)) return error.StateTypeMismatch;
        return @ptrCast(@alignCast(self.ptr.?));
    }

    pub fn getOrNull(self: Handle, comptime T: type) ?*T {
        return self.get(T) catch null;
    }
};

test "Handle set/get type-safe" {
    const St = struct { n: u32 };
    var s: St = .{ .n = 7 };
    var h: Handle = .{};
    h.set(St, &s);
    const got = try h.get(St);
    try std.testing.expectEqual(@as(u32, 7), got.n);
    const Other = struct { x: u8 };
    try std.testing.expectError(error.StateTypeMismatch, h.get(Other));
}
