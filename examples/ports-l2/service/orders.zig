//! Orders service — depends only on ports (no global DB / queue).
const std = @import("std");
const store_port = @import("../ports/store.zig");
const cache_port = @import("../ports/cache.zig");
const bus_port = @import("../ports/bus.zig");

pub const OrdersService = struct {
    store: store_port.Store,
    cache: cache_port.Cache,
    bus: bus_port.Bus,

    pub fn placeOrder(self: OrdersService, allocator: std.mem.Allocator, order_id: []const u8, payload: []const u8) !void {
        // ── ai-edit-zone: business rules ──────────────────────────────
        try self.store.put(allocator, order_id, payload);
        try self.cache.set(allocator, order_id, payload, 60);
        try self.bus.publish("order.placed", payload);
        // ── end ai-edit-zone ──────────────────────────────────────────
    }

    pub fn getOrder(self: OrdersService, allocator: std.mem.Allocator, order_id: []const u8) !?[]u8 {
        if (try self.cache.get(allocator, order_id)) |hit| return hit;
        return try self.store.get(allocator, order_id);
    }
};
