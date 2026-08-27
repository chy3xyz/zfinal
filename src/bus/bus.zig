//! Optional L3 message bus port — swap Memory / NATS / RobustMQ without
//! touching service code. See `doc/bus.md` and `doc/progressive_architecture.md`.

pub const Bus = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        publish: *const fn (ptr: *anyopaque, topic: []const u8, payload: []const u8) anyerror!void,
    };

    pub fn publish(self: Bus, topic: []const u8, payload: []const u8) !void {
        return self.vtable.publish(self.ptr, topic, payload);
    }
};

pub const MemoryBus = @import("memory_bus.zig").MemoryBus;
pub const NatsBus = @import("nats_bus.zig").NatsBus;
pub const RobustMQBus = @import("robustmq_bus.zig").RobustMQBus;

test {
    _ = @import("memory_bus.zig");
    _ = @import("nats_bus.zig");
    _ = @import("robustmq_bus.zig");
}
