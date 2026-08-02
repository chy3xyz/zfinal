# 渐进式代码架构（由小到大）

> **版本**：对齐 v0.20.9+ · 修订 **2026-07-31**  
> **反向设计原则**：从 [千万级支撑方案](scale_to_millions.md) 倒推——  
> **今天按最终形态的依赖方向写代码，但只实现当前阶段需要的组件。**  
> 这样 L0 → L3 升级时改的是 **装配与实现**，不是推翻三层目录。  
> **总索**：[best_practices.md](best_practices.md) · **架构规范**：[architecture_best_practices.md](architecture_best_practices.md)

**不变核心（全程遵守）：**

```
handler → service → model
  HTTP      业务       数据
```

- 用 `zf crud:sql` / `zf crud:zent` 生成模块；只改 `ai-edit-zone`
- 绿场路由优先 `actions.zig` + `zf routes`（v0.20.9+）
- 对外只用 `zfinal.*` 稳定 API；错误用 `HttpError` / `failHttp`

---

## 阶段总览

| 阶段 | 用户量级（粗） | 进程 | 数据 | 代码关键词 |
|------|----------------|------|------|------------|
| **L0** 单机验证 | 开发 / 内测 | 1 | SQLite | 三层 CRUD + 基础路由 |
| **L1** 生产入门 | 万级 MAU | 1（可备机） | SQLite→单库 PG | 限流、Metrics、可信代理、Cookie 安全 |
| **L2** 水平扩展 | 十万～百万 | N 无状态 | PG 主从 + Redis | 无 Session 本地态、读写分离端口、熔断 |
| **L3** 千万准备 | 千万注册 / 高峰值 | N + 异步 | 分片键 + MQ | `tenant_id`、幂等、Outbox / 队列端口 |

```
L0 ──加横切──► L1 ──抽端口+多实例──► L2 ──分片+异步──► L3
     不改三层目录        不改 handler 形状         service 编排变厚
```

---

## L0 — 单机验证（今天就能写）

### 目录

```
src/
├── main.zig
├── config/
│   └── routes.zig
└── modules/
    └── users/
        ├── model.zig      # zf 生成
        ├── service.zig    # ai-edit-zone: 业务
        ├── handler.zig    # ai-edit-zone: HTTP
        └── routes.zig
```

### 装配示意

```zig
// main.zig — L0
var app = zfinal.ZFinal.init(allocator);
defer app.deinit();
app.setPort(8080);

var db = try zfinal.DB.init(allocator, .{ .driver = .sqlite, .path = "app.db" });
defer db.deinit();

// 数据层二选一：上例为 SQL 主力。电商/社交可改为 zfinal.zent 作主力（doc/zent.md）。

// 把 *DB 注入 service（或经 app 扩展点），handler 只调 service
try users.routes.register(&app, svc);
try app.start();
```

### 规则

- Service **不**读环境里的「从库 URL」——L0 只有一个 `*DB`（或一套 zent Schema）。
- Handler **不**直接 `DB.init`；失败用 `return error.*` / `failHttp`，勿手搓错误 JSON。
- 允许进程内 `CachePlugin` / `QueueClient`（单机演示即可）。
- 路由：可用手写 `routes.register`；绿场更推荐 `actions.zig`（与 L1+ 同一真源）。

### 毕业标准

`zf check && zig build test` 绿；本地 CRUD 跑通。

---

## L1 — 生产入门（对照 `examples/production`）

### 在 L0 上增加（仍可不改 modules 目录）

```
src/
├── main.zig              # + Logger / Metrics / RateLimit / CSRF
├── interceptors/         # 可选：Logging / CORS
└── modules/…             # 不变
```

### 装配示意

```zig
// main.zig — L1 增量
var logger = zfinal.Logger.init(allocator);
zfinal.initGlobalLogger(logger);

var metrics = zfinal.Metrics.init(allocator);
defer metrics.deinit();
try app.get("/health", zfinal.healthHandlerFor(&metrics));

var rate = zfinal.RateLimitHandler.init(allocator);
defer rate.deinit();
// 反代后才打开：
// rate.trust_proxy_headers = true;
// rate.trusted_proxies = &.{"10.0.0.1"};

// Cookie / CSRF：走 Context 默认 HttpOnly+SameSite
```

### 规则

- 限流与真实 IP 策略集中在 **入口装配**，不散落在每个 handler。
- 拦截器 cfg **caller-owned**（禁止 `createX(&.{…})`）；见 [http_ergonomics.md](http_ergonomics.md)。
- 仍单库；可开始把 DSN 从环境变量读入（为 L2 换 PG 做准备）。
- 生产保持 `force_connection_close=true`（[reverse_proxy.md](reverse_proxy.md)）。

### 毕业标准

ReleaseSafe 可跑；`/health` 有指标；反代 TLS 文档化；`zf check --prod` 绿；压测基线有记录。

---

## L2 — 水平扩展（无状态 + 外置会话）

### 目录演进（引入「端口」，实现可替换）

```
src/
├── main.zig                 # 只做 DI 装配
├── ports/                   # 接口（Zig：函数指针 / 小 vtable / 具体类型参数）
│   ├── store.zig            # 读写 DB 抽象（主/从）
│   ├── cache.zig            # Redis 或 memory
│   └── clock.zig            # 可选：可测时间
├── adapters/
│   ├── pg_store.zig         # ConnectionPool + 主 DSN
│   ├── pg_replica.zig       # 只读 DSN（可先与主相同）
│   └── redis_cache.zig
└── modules/
    └── users/
        ├── service.zig      # 依赖 ports，不依赖「全局单例 DB」
        └── …
```

### Service 形状（关键进式关键）

```zig
// modules/users/service.zig — L2 目标形态（示意）
pub fn UsersService(comptime Store: type, comptime Cache: type) type {
    return struct {
        store: Store,   // 写：主库
        read: Store,    // 读：从库（L1 可等于 store）
        cache: Cache,

        pub fn getProfile(self: *@This(), allocator: Allocator, id: i64) !User {
            if (try self.cache.get(id)) |u| return u;
            const u = try self.read.findUser(allocator, id);
            try self.cache.set(id, u, 60);
            return u;
        }

        pub fn updateProfile(self: *@This(), allocator: Allocator, id: i64, patch: Patch) !void {
            try self.store.updateUser(allocator, id, patch);
            self.cache.invalidate(id);
        }
    };
}
```

### 装配示意

```zig
// main.zig — L2
var write_pool = try zfinal.ConnectionPool.init(allocator, primary_cfg, 20);
var read_pool = try zfinal.ConnectionPool.init(allocator, replica_cfg, 20);
var redis = try zfinal.RedisClient.connect(allocator, redis_url);
defer …;

var store = PgStore{ .pool = write_pool };
var replica = PgStore{ .pool = read_pool };
var cache = RedisCache{ .client = &redis };

var svc = UsersService(PgStore, RedisCache){ .store = store, .read = replica, .cache = cache };

// 多实例：禁止把登录态只放内存 HashMap
// Session → Redis；本地 Cache 仅短 TTL
```

### 规则

- **禁止**在 handler/service 里假设「只有一个进程」。
- 引入 `CircuitBreaker` 包住 Redis / 外部 HTTP（`HttpClient` / `OAuth2Client`）。
- 连接池：`每实例池深 × 实例数 < DB max_connections`（写进运维 runbook）。

### 毕业标准

≥2 实例无粘滞可登录；杀一台不丢会话；读多写少接口可指到 replica DSN。

---

## L3 — 千万准备（分片键 + 异步边界）

### 目录演进

```
src/
├── ports/
│   ├── store.zig
│   ├── cache.zig
│   └── bus.zig              # 消息总线端口（publish）
├── adapters/
│   ├── pg_store.zig         # SQL 必带 tenant_id / shard 键
│   ├── redis_cache.zig
│   ├── memory_bus.zig       # L0–L2 本地实现（QueueClient）
│   ├── robustmq_bus.zig     # L3：QueueRobustMQClient → RobustMQ Kafka :9092
│   └── nats_bus.zig         # L3：QueueNatsClient → NATS :4222（稳定，零依赖）
├── workers/                 # 可选：独立 binary 消费 MQ
│   └── notify_worker.zig
└── modules/
    └── orders/
        ├── model.zig        # 表含 tenant_id；唯一键含幂等键
        ├── service.zig      # 写库 + outbox / bus.publish
        └── handler.zig
```

### 领域约束（写进 model / service）

```zig
// 所有租户数据查询必须带租户键（示意）
pub fn findOrder(self: *Store, allocator: Allocator, tenant_id: i64, order_id: i64) !?Order {
    return try self.db.queryOne(
        \\SELECT * FROM orders WHERE tenant_id = ? AND id = ?
    , .{ tenant_id, order_id });
}

// 写路径：业务事务 + 投递意图（Outbox 或总线）
pub fn placeOrder(self: *OrdersService, …, idempotency_key: []const u8) !OrderId {
    // 1) UNIQUE(tenant_id, idempotency_key) 防重
    // 2) INSERT order
    // 3) 同事务写入 DbOutbox（推荐）或 bus.publish
    //    见 doc/outbox.md：DbOutbox.port().append(…, idempotency_key)
}
```

### 规则

- Handler 解析并传入租户键（JWT / 头），**禁止** service 默认 `tenant_id=0` / `app_id=0` 扫全表。
- **字段名 comptime 配置**：默认 `zfinal.tenant.tenant_id`；ZigShop 用 `zfinal.tenant.app_id`
  （`app_id` + `X-App-Id`）。`extract.requireTenant(ctx, comptime cfg)`。见 [http_ergonomics.md](http_ergonomics.md)。
- 跨机异步：领域写 + **`zfinal.DbOutbox`** 同 TX（见 [outbox.md](outbox.md)），worker 再
  `Bus.publish`。`QueueClient` / `MemoryBus` 便于单测；L3 用 `NatsBus` /
  `RobustMQBus`（[bus.md](bus.md)）。另有 `Store` / `Cache` / `Outbox` Memory
  适配器；`zf g port bus` 生成 re-export。
- 分片：先在 SQL / 缓存 key 带上分片键；物理分库可后置，避免提前拆模块。

### 毕业标准

幂等压测无双写；打挂一个 worker 可重放；跨租户误查在代码审查 / 测试中可拦。

---

## 依赖方向（全程冻结）

```
handler ──► service ──► ports ◄── adapters
                │
                └──► model（纯数据 / ORM 映射）

main.zig 只组装 adapters → ports → service → routes
```

**禁止：**

- handler → DB / Redis 直连  
- model → HTTP Context  
- service → 具体 `nats.zig`（应经 `ports/bus`）  
- 为了 L3 提前把 L0 目录拆成微服务（先模块化，后拆进程）

---

## 阶段对照：方案能力 → 代码落点

| 支撑方案要求 | 最早阶段 | 代码落点 |
|--------------|----------|----------|
| 三层 CRUD | L0 | `modules/*/…` + `zf` |
| TLS / 可信代理 / 限流 | L1 | `main` + `RateLimitHandler` |
| Metrics / health | L1 | `Metrics` + `healthHandlerFor` |
| 无状态多实例 | L2 | Session→Redis；禁内存登录态 |
| PG 主从 | L2 | `store` vs `read` 两个端口 |
| 熔断外部依赖 | L2 | `CircuitBreaker` 包 adapters |
| 租户 / 分片键 | L3 | model 字段 + 查询强制谓词 |
| 异步削峰 | L3 | `ports/bus` → RobustMQ（Kafka）或 NATS |
| 图关系密（订单/关注） | L2+ | **`zfinal.zent` 作主力**（见 `doc/zent.md`）；`DB` 仅旁路 |
| 平 CRUD / 存量 SQL | L0+ | **`DB`/`Model` + `zf` 作主力** |
| CDN / 对象存储 | L1+ | handler 只返回 URL，不接大文件流 |

---

## 迁移检查清单（升级时用）

### L0 → L1

- [ ] `/health` + 结构化日志 + Metrics  
- [ ] 限流与代理策略只在装配层配置（caller-owned cfg）  
- [ ] Cookie / CSRF / SecurityHeaders / RequestId  
- [ ] `force_connection_close=true` + 反代文档  

### L1 → L2

- [ ] DSN / Redis URL 环境变量化  
- [ ] Service 经 Store/Cache 端口注入（`zf g port` / `examples/ports-l2`）  
- [ ] 双实例验证会话  
- [ ] 池大小写入部署文档  

### L2 → L3

- [ ] 表与缓存 key 含 `tenant_id`（或等价分片键；`extract.requireTenant`）  
- [ ] 写路径幂等键  
- [ ] `bus` 端口 + 至少一种跨机适配器（或 outbox；`examples/ports-l3`）  
- [ ] worker 可独立部署  

---

## 与示例 / 文档的映射

| 文档或示例 | 对应阶段 |
|------------|----------|
| `zf new` / `examples/hello-world` | L0 |
| `examples/smart-routing` | L0+ 路由真源 |
| `examples/production` | L1 |
| `zf g port store\|cache\|bus` | 生成 `src/ports` + `src/adapters` 脚手架 |
| `examples/ports-l2` (`zig build run-ports-l2`) | L2 DI 可抄示例 |
| `examples/ports-l3` (`zig build run-ports-l3`) | L3 tenant + outbox + 幂等可抄示例 |
| [best_practices.md](best_practices.md) | 总索 + 能力时间线 |
| [architecture_best_practices.md](architecture_best_practices.md) | 全程规范 |
| [`PRODUCTION_AUDIT.md`](../PRODUCTION_AUDIT.md) | L1+ 部署契约 |

---

## 一句话

**按千万级的拓扑规划端口与依赖方向，按当前用户量只装配需要的适配器；**  
三层模块与 `ai-edit-zone` 从 L0 到 L3 保持稳定，变的是 **main 的 DI 与 adapters**。
