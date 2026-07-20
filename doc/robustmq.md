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

- Implements ApiVersions + Produce + Fetch; **RecordBatch value decode is implemented**
  (`parseFetchValues` / `parseRecordBatchValues`). Consumer group protocol
  (JoinGroup / SyncGroup / OffsetCommit) is still incomplete.
- Prefer `QueueRobustMQClient.publish` for L3 `ports/bus` until group consume matures;
  for mature consume prefer NATS (`QueueNatsClient`).

See also: [progressive_architecture.md](progressive_architecture.md), [scale_to_millions.md](scale_to_millions.md).
