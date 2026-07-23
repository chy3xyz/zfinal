//! Orders service — tenant-scoped keys, outbox, and bus (L3).
const std = @import("std");
const store_port = @import("../ports/store.zig");
const cache_port = @import("../ports/cache.zig");
const bus_port = @import("../ports/bus.zig");
const outbox_port = @import("../ports/outbox.zig");

pub const OrdersService = struct {
    store: store_port.Store,
    cache: cache_port.Cache,
    bus: bus_port.Bus,
    outbox: outbox_port.Outbox,

    pub fn placeOrder(
        self: OrdersService,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        order_id: []const u8,
        idempotency_key: []const u8,
        payload: []const u8,
    ) !void {
        // ── ai-edit-zone: business rules ──────────────────────────────
        var store_key_buf: [256]u8 = undefined;
        const store_key = try std.fmt.bufPrint(&store_key_buf, "tenant:{s}:order:{s}", .{ tenant_id, order_id });

        var idem_buf: [256]u8 = undefined;
        const idem_key = try std.fmt.bufPrint(&idem_buf, "tenant:{s}:idempotency:{s}", .{ tenant_id, idempotency_key });
        if (try self.store.get(allocator, idem_key)) |existing| {
            allocator.free(existing);
            return;
        }

        try self.store.put(allocator, store_key, payload);
        try self.store.put(allocator, idem_key, order_id);
        try self.cache.set(allocator, store_key, payload, 60);
        try self.outbox.append(allocator, "order.placed", payload, idempotency_key);
        try self.bus.publish("order.placed", payload);
        // ── end ai-edit-zone ──────────────────────────────────────────
    }

    pub fn getOrder(
        self: OrdersService,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        order_id: []const u8,
    ) !?[]u8 {
        var store_key_buf: [256]u8 = undefined;
        const store_key = try std.fmt.bufPrint(&store_key_buf, "tenant:{s}:order:{s}", .{ tenant_id, order_id });
        if (try self.cache.get(allocator, store_key)) |hit| return hit;
        return try self.store.get(allocator, store_key);
    }
};
