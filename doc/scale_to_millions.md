# 千万级用户支撑方案

> **版本**：对齐 v0.20.13+ · 修订 **2026-08-02**  
> **相关**：[progressive_architecture.md](progressive_architecture.md) · [outbox.md](outbox.md) · [bus.md](bus.md) · [architecture_best_practices.md](architecture_best_practices.md) · [best_practices.md](best_practices.md) · [`PRODUCTION_AUDIT.md`](../PRODUCTION_AUDIT.md) · [reverse_proxy.md](reverse_proxy.md)

**结论：**「千万级用户」通常指注册量 / 月活，不是单机千万并发。  
ZFinal 适合做 **无状态 API / BFF 节点**；要靠 **水平扩展 + 外部数据面** 撑住。  
单实例（默认 `max_connections=10000`、且当前强制 `Connection: close`）不能扛全站峰值。

反向的代码怎么长，见 **[渐进式代码架构](progressive_architecture.md)**。

---

## 1. 先拆指标

| 指标 | 典型量级（举例） | 含义 |
|------|------------------|------|
| 注册 / 月活 | 1000 万+ | 业务规模 ≠ 同时在线 |
| 日活 DAU | 例如 50–200 万 | 决定库与缓存容量 |
| 峰值 QPS | 例如 1 万–10 万+ | 决定实例数与 DB 读写比 |
| 峰值并发连接 | 远小于用户数 | 受 keep-alive、反代、超时影响 |

按 **峰值 QPS × P99 延迟 × 安全余量** 算节点数，不要按「一千万用户开一千万连接」估算。

---

## 2. 目标拓扑

```
CDN / 静态 / 对象存储
        ↓
L7 负载均衡（多 AZ）
        ↓
反向代理（TLS、限流、WAF）  ← 可信代理 IP 只信任这里
        ↓
ZFinal 无状态实例 × N（ReleaseSafe，钉死 Zig）
        ↓
┌──────────────┬──────────────┬─────────────────┐
│ PG / MySQL   │ Redis        │ MQ（跨机异步）   │
│ 主写从读/分片 │ 会话 / 热点  │ 发信 / 结算等    │
└──────────────┴──────────────┴─────────────────┘
```

### 运维要点

1. **应用无状态**：Session 进 Redis；本地 `CachePlugin` 只做短 TTL，不当全站真相源。
2. **SQLite 不进多节点写路径**：千万级用 PostgreSQL / MySQL；SQLite 仅单机 / 边车 / 开发。
3. **读写分离**：列表走从库；写走主库；热点走 Redis。
4. **异步削峰**：下单、推送、报表 → **同 TX 写 Outbox**（[`DbOutbox`](outbox.md)）再 `drainOnce` → **Bus**（[bus.md](bus.md)）到 **RobustMQ** / **NATS**；进程内 `MemoryBus`/`QueueClient` 仅单进程/单测。不要用 Bus 替代持久投递意图。
5. **保护下游**：`CircuitBreaker` + 反代/应用双层限流；严格控制「实例数 × 连接池」。
6. **观测**：Metrics / Prometheus + `/health`；Outbox 可用 `toPrometheusFormat`；按延迟与错误率扩缩容。

部署契约见 [`PRODUCTION_AUDIT.md`](../PRODUCTION_AUDIT.md)。

---

## 3. 与 ZFinal 现状相关的硬约束

| 现状 | 千万级含义 |
|------|------------|
| 强制 `Connection: close` | 同样 QPS 需要更多节点；**客户端 keep-alive 放反代**（[reverse_proxy.md](reverse_proxy.md)） |
| 单进程 `max_connections` 默认 1 万 | 靠多实例，不要调成「一个超大数字」指望单机扛全站 |
| Zig 仍是 **dev** 编译器 | 钉版本 + 回归 + 灰度 |
| PG / MySQL 默认不在 CI | 上线前对真实驱动做压测与 soak |
| 进程内 Queue / 部分 experimental | 跨机能力靠外部中间件 |

---

## 4. 数据与业务层

1. **按用户 / 租户分片**（`user_id` / `tenant_id` 哈希）——写放大后再分，不要一上来过度设计。
2. **热冷分离**：时间线、日志、消息进冷库或对象存储。
3. **幂等**：支付、发券用唯一键 + 幂等 token。
4. **CDN + 对象存储**：大文件不经 ZFinal。
5. **多租户**：在线查询一律带租户键；跨租户聚合走离线任务。

---

## 5. 容量粗算（示意）

假设峰值 **2 万 QPS**，单实例稳定约 **2k QPS**（强制 close 后偏保守）：

- 应用：约 **15–20** 实例（含 30–50% 余量）
- DB 连接：`实例数 × 每实例池`（例 20×20=400）须低于 DB `max_connections`
- Redis：按 DAU × 会话大小估内存

压测必须在 **真实 close、真实 SQL、真实 Redis** 下跑。

---

## 6. 能力演进路线（与代码阶段对齐）

| 阶段 | 基础设施 | 代码阶段（见 progressive 文档） |
|------|----------|--------------------------------|
| 短期 | 多副本 + PG 主从 + Redis + 反代限流 | L0 → L1 → L2 |
| 中期 | keep-alive 恢复、驱动进 CI、跨机 MQ 稳定化 | L2 加固 |
| 长期 | 分片路由、多活、事件驱动核心链路 | L3 |

---

## 7. 验证清单

```bash
# 应用
zig build -Doptimize=ReleaseSafe
zig build test
curl -sS http://127.0.0.1:8080/health

# 压测前确认
# - 反代 TLS + trusted_proxies；upstream 短连接（见 reverse_proxy.md）
# - ZFinal force_connection_close=true（默认）
# - DB 为 PG/MySQL，非 SQLite 多写
# - Session/热点在 Redis
# - 连接池 × 实例数 < DB max_connections
```
