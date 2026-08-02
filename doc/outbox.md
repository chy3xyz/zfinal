# Outbox（事务外发）

L3 异步投递：业务写库与「待发布事件」同事务提交，worker 再 `Bus.publish` → NATS / RobustMQ。

| 类型 | 用途 |
|------|------|
| `zfinal.Outbox` | 端口（`append` + 幂等键） |
| `zfinal.MemoryOutbox` | 单测 / 进程内 |
| `zfinal.DbOutbox` | SQLite 表 `zfinal_outbox`（`UNIQUE(idempotency_key)`） |
| `zfinal.OutboxRow` | `fetchUnpublished` 行 |

## 推荐写路径

```zig
var box = try zfinal.DbOutbox.init(allocator, db);
defer box.deinit();

try db.begin();
try db.exec("INSERT INTO orders …");
try box.port().append(allocator, "order.placed", payload, idempotency_key);
try db.commit();

// worker（可另进程）
const batch = try box.fetchUnpublished(allocator, 100);
defer zfinal.DbOutbox.freeBatch(allocator, batch);
for (batch) |row| {
    try bus.publish(row.event_type, row.payload);
    try box.markPublished(row.id);
}
```

`INSERT OR IGNORE`：同一 `idempotency_key` 不产生重复行。

## 与 Bus 的关系

- Outbox = **持久意图**（与领域写同 TX）
- `zfinal.Bus` = **投递适配器**（Memory / NATS / RobustMQ）
- 不要用 Bus 替代 Outbox 做跨进程至少一次语义；见 [progressive_architecture.md](progressive_architecture.md)、[bus.md](bus.md)
