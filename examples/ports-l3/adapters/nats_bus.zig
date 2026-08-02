//! NATS bus — re-export `zfinal.NatsBus` (L3). Wire a connected `QueueNatsClient`.
//!
//! ```zig
//! var q = try zfinal.QueueNatsClient.connect(allocator, "nats://127.0.0.1:4222");
//! defer q.deinit();
//! var nats_bus = zfinal.NatsBus.init(&q);
//! const bus = nats_bus.port(); // inject into service
//! ```
pub const NatsBus = @import("zfinal").NatsBus;
