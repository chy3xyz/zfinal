# NATS connector (stable)

Zero-dependency NATS wire client for ZFinal, ported from zigmodu `Nats.zig`.

| Backend | Type | API |
|---------|------|-----|
| Memory | In-process | `QueueClient` / `MessageQueue` |
| **NATS** | NATS TCP `:4222` | `QueueNatsClient` / `NatsClient` |
| RobustMQ | Kafka TCP `:9092` | `QueueRobustMQClient` / `KafkaProducer` |

No `nats.zig` package and no `-Denable-nats` flag — ships with the framework.

## Quick start

```zig
const zfinal = @import("zfinal");

var q = try zfinal.QueueNatsClient.connect(allocator, "nats://127.0.0.1:4222");
defer q.deinit();

try q.publish("orders.new", "{\"id\":1}");

const sid = try q.subscribe("orders.new", struct {
    fn onMsg(msg: zfinal.QueueNatsClient.Message) void {
        _ = msg;
    }
}.onMsg);
defer q.unsubscribe(sid) catch {};

_ = try q.poll();
try q.ping();
```

Low-level:

```zig
var nc = zfinal.NatsClient.init(allocator, zfinal.io_instance.io, .{
    .url = "127.0.0.1",
    .port = 4222,
    .name = "my-app",
});
defer nc.deinit();
_ = try nc.connect();
try nc.publish("demo", "hi");
```

## Live smoke

```bash
# nats-server listening on 4222
NATS_URL=127.0.0.1 zig build test
# or: NATS_URL=nats://127.0.0.1:4222 zig build test
```

Skipped when `NATS_URL` is unset. CI: `messaging-live` (`nats:2.10`) runs pub/sub soak
with delivery asserts.

## Migration

```zig
// before
const q = zfinal.experimental.QueueNatsClient; // required external nats.zig

// after
const q = zfinal.QueueNatsClient; // stable, zero dep
```

`zfinal.experimental.QueueNatsClient` remains a deprecated alias.

L3 apps: prefer `zfinal.NatsBus` over the raw client in services
([bus.md](bus.md)).

See also: [robustmq.md](robustmq.md), [progressive_architecture.md](progressive_architecture.md).
