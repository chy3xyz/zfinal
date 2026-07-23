//! Async bus port (L3-ready). L0–L2 use memory; L3 swaps NATS / RobustMQ adapters.
const std = @import("std");

pub const Bus = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // ── ai-edit-zone: port ops ────────────────────────────────
        publish: *const fn (ptr: *anyopaque, topic: []const u8, payload: []const u8) anyerror!void,
        // ── end ai-edit-zone ──────────────────────────────────────
    };

    pub fn publish(self: Bus, topic: []const u8, payload: []const u8) !void {
        return self.vtable.publish(self.ptr, topic, payload);
    }
};
