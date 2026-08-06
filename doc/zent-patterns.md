# ZFinal × zent 进阶模式（P2 生态）

> 面向已跑通 `examples/zent-shop` 的商城/社交系统。这些是**可选模式**：
> 通用 CRUD 服务 + 变更事件、事务 Outbox、生产连接池、鉴权、分片。
> 相关：[zent-commerce-social.md](zent-commerce-social.md)（基础）· [outbox.md](outbox.md)（zfinal 侧）· [bus.md](bus.md)

## 1. 通用 CRUD 服务 + 变更事件（`crud.CrudService`）

zent 的 `crud.CrudService(infos, info, tenant_col)` 提供 list/get/create/update/
delete 骨架，写操作后通过 `on_event` 回调发布 `CrudEvent{created,updated,deleted}`
—— feed / 通知 / 审计的**事件源**，避免在每个 service 手写重复 CRUD：

```zig
// persistence.zig ── ai-edit-zone: custom queries
const CrudSvc = zent.crud.CrudService(infos, OrderInfo, "buyer_id");
var crud = CrudSvc.init(allocator, client.order, .{
    .on_event = &onOrderEvent, // fn(CrudEvent(infos, OrderInfo)) void
});
const page = try crud.list(page, size, .{ .where = ... });
```

- 事件在**写事务提交后**触发（after-hook 面），跨模块副作用走 Queue 而非同事务。
- 与生成器的 `create/update/delete` 方法二选一：生成器方法适合业务定制多的实体，
  CrudService 适合纯管理端点（后台列表）。

## 2. 事务 Outbox（`zent.outbox`）

领域事件与业务写入**同事务**落库，后台轮询分发（at-least-once）：

```zig
// 1. schema 图包含 outbox 表（迁移自动建）
const graph = zentBuildGraph(&.{ model.User, model.Product, zent.outbox.OutboxMessage });
// 2. 业务事务内 enqueueEvent（TxClient）：
var txc = try zent.codegen.client.beginTx(infos, self.client);
defer txc.deinit();
// ... 业务写入 ...
try txc.enqueueEvent("{\"type\":\"order.created\",\"order_id\":123}");
try txc.commit(); // 事件与业务原子可见
// 3. 后台 dispatcher：zent.outbox.pollAndDispatch(...) 轮询 pending → 发布
```

- zfinal 侧等价物：`DbOutbox.drainOnce`（`doc/outbox.md`）—— 二选一，别双写。
- 跨模块（zent 模块 → DB 模块）事件：`QueueNatsClient` / `QueueRobustMQClient` /
  进程内 `QueueClient`（`doc/bus.md`）。

## 3. 生产连接池（`sql_pool.ConnPool`）

`examples/zent-shop` 用单连接 SQLite（开发/演示）。生产多连接：

```zig
const Pool = zent.sql_pool.ConnPool(zent.sql_sqlite.SQLiteDriver);
var pool = try Pool.init(allocator, .{
    .connect = struct {
        fn c(a: std.mem.Allocator) !zent.sql_sqlite.SQLiteDriver {
            return zent.sql_sqlite.SQLiteDriver.open(a, "app.db");
        }
    }.c,
    .max_idle = 10, .max_total = 64,
});
defer pool.deinit();
const conn = try pool.borrow();
defer pool.release(conn);
const store = persist.ShopStore.init(allocator, conn.asDriver());
// 注意：asDriver() 的 ptr 指向调用者实例 —— conn 必须存活到 Store 用完
```

- **事务边界**：一个事务只用一套驱动；池化后每个请求 borrow 一个连接，
  请求结束 release。PG/MySQL 用 `zent.sql_postgres.PostgresDriver` /
  `zent.sql_mysql.MySQLDriver` 同样包装进 `ConnPool`。
- 与 `zfinal.DB` 的连接池互不混用（两套池各自管理）。

## 4. 鉴权 / WebSocket 握手鉴权

- **REST**：`JwtAuthInterceptor`（zfinal）校验请求头；handler 里
  `ctx.getHeader("Authorization")` → 解析出 `user_id` 再调 zent service。
  业务写路径把 `user_id` 显式传参（zent 无全局 session），配合
  `data_scope.Policy`（`zent-commerce-social.md` §2.3）做行级隔离。
- **WebSocket**：握手 URL query 已可用（`ws.queryParam("room_id")`，
  `zent-commerce-social.md` 有例）。鉴权：握手时带 `?token=` 或
  `Sec-WebSocket-Protocol` 子协议名，handler 首帧校验后 `ws.close(1008)`：
  ```zig
  const token = ws.queryParam("token") orelse return ws.close(1008);
  const uid = jwt.verify(token) catch return ws.close(1008);
  ```

## 5. 分片（`zent.shard`）

`zent.shard` 提供分片路由（hash → shard 连接）。适合单表超单库容量
（约见 `doc/scale_to_millions.md` 的容量模型）。**先确认单库瓶颈再引入**：
- 常用分片键：`user_id`（订单/关注按用户切）、`tenant_id`（多租户天然分片）。
- 跨分片事务**不做**（与"一事务一套驱动"一致）——跨分片读走汇总/Queue。

## 参考

- zent v0.27 源码：`src/crud.zig`、`src/outbox.zig`、`src/sql/pool.zig`、`src/shard.zig`
- `doc/outbox.md`（zfinal DbOutbox）、`doc/bus.md`（Queue 端口）
- `doc/scale_to_millions.md`（容量与拓扑）
