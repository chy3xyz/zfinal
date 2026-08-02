# Optional Bus port — Memory / NATS / RobustMQ

ZFinal does **not** require an in-process EventBus WAL. For cross-host async
(L3), use the optional **`Bus`** port and swap adapters:

| Adapter | Backing | When |
|---------|---------|------|
| `zfinal.MemoryBus` | `QueueClient` | L0–L2, unit tests, single process |
| `zfinal.NatsBus` | `QueueNatsClient` | Multi-instance consume (queue groups) |
| `zfinal.RobustMQBus` | `QueueRobustMQClient` | Kafka / RobustMQ publish path |

Service code depends only on `Bus.publish(topic, payload)`.

## Quick use

```zig
// L0–L2
var mem = zfinal.MemoryBus.init(allocator);
defer mem.deinit();
const bus: zfinal.Bus = mem.port();
try bus.publish("order.placed", payload);

// L3 NATS
var q = try zfinal.QueueNatsClient.connect(allocator, "nats://127.0.0.1:4222");
defer q.deinit();
var nats_bus = zfinal.NatsBus.init(&q);
try nats_bus.port().publish("order.placed", payload);

// L3 RobustMQ / Kafka
var mq = zfinal.QueueRobustMQClient.connect(allocator, "127.0.0.1:9092");
defer mq.deinit();
var mq_bus = zfinal.RobustMQBus.init(&mq);
try mq_bus.port().publish("order.placed", payload);
```

## App layout

`zf g port bus` generates `src/ports/bus.zig` + adapters as **re-exports** of
the framework types. Or inject `zfinal.Bus` directly (see `examples/ports-l3`).

Prefer **Outbox** (same TX as business write) + bus publish from a worker when
you need at-least-once delivery under crash. See
[progressive_architecture.md](progressive_architecture.md) L3.

## Related

- [nats.md](nats.md) — `QueueNatsClient`
- [robustmq.md](robustmq.md) — `QueueRobustMQClient`
- [scale_to_millions.md](scale_to_millions.md) — topology
