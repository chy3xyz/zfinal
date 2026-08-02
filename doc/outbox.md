# Outbox（事务外发）

L3 异步投递：业务写库与「待发布事件」同事务提交，worker 再 `Bus.publish` → NATS / RobustMQ。

| 类型 | 用途 |
|------|------|
| `zfinal.Outbox` | 端口（`append` + 幂等键） |
| `zfinal.MemoryOutbox` | 单测 / 进程内 |
| `zfinal.DbOutbox` | 持久表 `zfinal_outbox`（SQLite / PG / MySQL DDL） |
| `zfinal.OutboxRow` | `fetchUnpublished` 行 |
| `drainOnce` | poll → publish → mark；失败重试 / 死信 |

## 推荐写路径

```zig
var box = try zfinal.DbOutbox.init(allocator, db);
defer box.deinit();

try db.begin();
try db.exec("INSERT INTO orders …");
try box.port().append(allocator, "order.placed", payload, idempotency_key);
try db.commit();

// worker tick（Cron / 独立进程）
const st = try box.drainOnce(allocator, bus, .{ .batch_limit = 100, .max_attempts = 8 });
_ = st; // published / failed / dead
```

幂等：`UNIQUE(idempotency_key)` + 方言插入（SQLite `OR IGNORE` / PG `ON CONFLICT DO NOTHING` / MySQL `INSERT IGNORE`）。

失败：`markFailed` 递增 `attempts`，达到 `max_attempts` 写 `dead_at_ms`（死信，不再投递）。

观测：`box.toPrometheusFormat(allocator)` → `zfinal_outbox_unpublished` / `zfinal_outbox_dead`。

生产示例：默认 `MemoryOutbox`；`ZF_OUTBOX_DB=./outbox.db zig build run-production` 切到 `DbOutbox`。
Live 方言：`ZF_PG_*` / `ZF_MY_*` + `-Ddriver_pg=true -Ddriver_mysql=true` 跑 `DbOutbox live drainOnce`。

## 与 Bus 的关系

- Outbox = **持久意图**（与领域写同 TX）
- `zfinal.Bus` = **投递适配器**（Memory / NATS / RobustMQ）
- 不要用 Bus 替代 Outbox 做跨进程至少一次语义；见 [progressive_architecture.md](progressive_architecture.md)、[bus.md](bus.md)
