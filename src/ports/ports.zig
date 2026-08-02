//! Optional L2/L3 ports: Store / Cache / Outbox (see `doc/bus.md`, progressive architecture).

pub const Store = @import("store.zig").Store;
pub const MemoryStore = @import("memory_store.zig").MemoryStore;

pub const Cache = @import("cache.zig").Cache;
pub const MemoryCache = @import("memory_cache.zig").MemoryCache;

pub const Outbox = @import("outbox.zig").Outbox;
pub const MemoryOutbox = @import("memory_outbox.zig").MemoryOutbox;
pub const DbOutbox = @import("db_outbox.zig").DbOutbox;
pub const OutboxRow = @import("db_outbox.zig").OutboxRow;

test {
    _ = @import("memory_store.zig");
    _ = @import("memory_cache.zig");
    _ = @import("memory_outbox.zig");
    _ = @import("db_outbox.zig");
}
