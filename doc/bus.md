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
you need at-least-once delivery under crash. See [outbox.md](outbox.md) /
[progressive_architecture.md](progressive_architecture.md) L3.

## Consume

| Adapter | Consume API |
|---------|-------------|
| `MemoryBus` | `bus.queueClient().subscribe(topic)` → mailbox `tryPop` |
| `NatsBus` | `subscribe` / `subscribeGroup` + `poll` (queue groups for workers) |
| `RobustMQBus` | publish-only port; pair with `KafkaConsumer.subscribe` + `poll` |

Offline unit tests assert `NotConnected` / subscribe pairing without a live broker.
Live soak: set `NATS_URL` / `KAFKA_BOOTSTRAP` / `ROBUSTMQ_URL` (CI job
`messaging-live` in `.github/workflows/ci.yml`).

## Related

- [outbox.md](outbox.md) — `DbOutbox.drainOnce`
- [nats.md](nats.md) — `QueueNatsClient`
- [robustmq.md](robustmq.md) — `QueueRobustMQClient` / `KafkaConsumer`
- [scale_to_millions.md](scale_to_millions.md) — topology

## WebSocket 多实例 fanout（`WsFanout`）

单实例广播用 `WebSocketManager.broadcast`；跨实例 fanout = 生产侧用
跨进程 pub/sub（Redis `PUBLISH`/NATS/RobustMQ）投递，**每个实例**用
`WsFanout` 订阅并把消息转发到本地 WS 连接：

```zig
// 生产侧（任意实例）：Redis 发布
try redis_client.publish("ws:events", payload);          // 或 NATS/RobustMQ publish

// 每个实例：订阅 → 本地广播
var qc = zfinal.QueueClient.init(allocator);
const mb = try qc.subscribe("ws:events");
_ = try zfinal.WsFanout.startBroadcast(allocator, &ws_manager, mb, "ws:events");
// 收到消息 → ws_manager.broadcast(payload)（本实例所有连接）
```

- 内存 `QueueClient` 用于单进程 fanout/测试；跨进程后端用
  `QueueNatsClient`/`QueueRobustMQClient`（或 Redis `SUBSCRIBE`，收消息桥见
  `RedisClient`）。
- `WsFanout.start(..., on_message, ctx)` 回调式变体可接任意 sink（不限于 WS）。

## 分布式限流（`RedisRateLimiter`）

`RateLimitHandler` 是单实例内存计数；多实例精确限流用 Redis 原子窗口：

```zig
var rl = zfinal.RedisRateLimiter.init(&redis_client, "zfinal:rl:");
// INCR + 首次 EXPIRE；超 max 在 window 秒内 → false
if (!try rl.allow(user_id, 100, 60)) return error.TooManyRequests;
```

**fail-closed**：Redis 不可用（`NotConnected` 等）→ `allow` 返回错误（**不会静默放行**），
由调用方显式决定降级策略（拒绝 / 回退内存 / 熔断）。
