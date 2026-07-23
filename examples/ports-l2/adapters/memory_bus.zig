//! In-process bus via `zfinal.QueueClient` (L0–L2). L3: swap nats_bus / robustmq_bus.
const std = @import("std");
const zfinal = @import("zfinal");
const ports = @import("../ports/bus.zig");

pub const MemoryBus = struct {
    queue: zfinal.QueueClient,

    pub fn init(allocator: std.mem.Allocator) MemoryBus {
        return .{ .queue = zfinal.QueueClient.init(allocator) };
    }

    pub fn deinit(self: *MemoryBus) void {
        self.queue.deinit();
    }

    pub fn port(self: *MemoryBus) ports.Bus {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // ── ai-edit-zone: adapter impl ───────────────────────────────
    fn publishImpl(ptr: *anyopaque, topic: []const u8, payload: []const u8) anyerror!void {
        const self: *MemoryBus = @ptrCast(@alignCast(ptr));
        try self.queue.publish(topic, payload);
    }
    // ── end ai-edit-zone ─────────────────────────────────────────

    const vtable = ports.Bus.VTable{ .publish = publishImpl };
};
