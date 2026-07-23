# RobustMQ / Kafka connector

ZFinal speaks **RobustMQ** through the Kafka wire protocol (default `127.0.0.1:9092`),
ported from zigmodu `KafkaConnector` — **zero third-party deps**.

| Backend | Type | When to use |
|---------|------|-------------|
| `QueueClient` / `MessageQueue` | In-process | L0–L1, single process |
| `QueueNatsClient` / `NatsClient` | NATS TCP → nats-server / RobustMQ NATS port | L2–L3 NATS clusters |
| `QueueRobustMQClient` / `KafkaProducer` | Kafka TCP → RobustMQ | L2–L3 Kafka / multi-protocol |


RobustMQ itself is a unified engine (MQTT + Kafka + NATS + …). Publishing via
Kafka protocol to topic `T` can be consumed by MQTT/NATS clients on the same
topic when the broker is configured for multi-protocol.

## Quick start

```zig
const zfinal = @import("zfinal");

// Offline (tests)
var q = zfinal.QueueRobustMQClient.connectOffline(allocator);
defer q.deinit();
try q.publish("orders.created", "{\"id\":1}");

// Online → RobustMQ Kafka listener
var online = zfinal.QueueRobustMQClient.connect(allocator, "127.0.0.1:9092");
defer online.deinit();
try online.publish("orders.created", "{\"id\":1}");

// Low-level producer
var producer = zfinal.KafkaProducer.initWithIo(allocator, zfinal.io_instance.io, .{
    .bootstrap_servers = "127.0.0.1:9092",
    .client_id = "my-app",
    .acks = .leader,
});
defer producer.deinit();
try producer.send(.{
    .topic = "orders.created",
    .key = "42",
    .value = "{\"id\":42}",
    .headers = &.{},
    .timestamp = 0,
});
```

## Live smoke test

```bash
# Start RobustMQ (or Kafka-compatible broker) on 9092, then:
ROBUSTMQ_URL=127.0.0.1:9092 zig build test
# or: KAFKA_BOOTSTRAP=127.0.0.1:9092 zig build test
```

Skipped automatically when env is unset.

## Scope / limits

| Capability | Status |
|------------|--------|
| ApiVersions + Produce + Fetch | Done |
| RecordBatch value decode | Done (`parseFetchValues`) |
| Local offset cursor + `commitLocal` | Done (per topic/partition) |
| OffsetCommit wire (API key 8) | Done — pass generation/member from `join()` |
| JoinGroup / SyncGroup / Heartbeat | Done |
| OffsetFetch / LeaveGroup | Done — `fetchCommittedOffset` / `leave` |
| Classic **range** rebalance | Done — leader divides partitions by member_id; `poll` uses assigned partitions |
| **Metadata** partition discovery | Done — `partition_count=0` (default) queries Metadata v1 per topic; `>0` overrides |

### L3 consume guidance

- **Publish** to RobustMQ/Kafka: `QueueRobustMQClient` / `KafkaProducer`.
- **Multi-instance Kafka consume** (same group): `subscribe` → `join()` → `poll` / `heartbeat` → `leave()`. Partition counts are discovered via Metadata unless you set `partition_count`.
- **NATS** remains a good alternative when you want queue-groups without managing partitions.

```zig
var consumer = zfinal.KafkaConsumer.initWithIo(allocator, zfinal.io_instance.io, .{
    .bootstrap_servers = "127.0.0.1:9092",
    .group_id = "orders-workers",
    // .partition_count = 0, // default: Metadata discover
    // .partition_count = 4, // optional override
});
defer consumer.deinit();
try consumer.subscribe("orders.created", onMsg);
try consumer.join(); // range-assigns partitions across group members
consumer.start();
_ = try consumer.poll();
try consumer.heartbeat();
try consumer.leave();
```

See also: [nats.md](nats.md), [progressive_architecture.md](progressive_architecture.md), [scale_to_millions.md](scale_to_millions.md).
