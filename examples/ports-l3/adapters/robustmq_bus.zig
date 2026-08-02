//! RobustMQ / Kafka bus — re-export `zfinal.RobustMQBus` (L3).
//!
//! ```zig
//! var q = zfinal.QueueRobustMQClient.connect(allocator, "127.0.0.1:9092");
//! defer q.deinit();
//! var mq_bus = zfinal.RobustMQBus.init(&q);
//! const bus = mq_bus.port();
//! ```
pub const RobustMQBus = @import("zfinal").RobustMQBus;
