# 商城 / 社交类业务：zfinal + zent 主力架构实战指南

> **适用**：电商（目录/购物车/订单/库存）、社交（关注图/动态/点赞/评论）、以及两者叠加的
> 内容电商 / 社区电商。**决策**：这类系统以 **zent 作数据层主力**（见
> [doc/zent.md](zent.md)），ZFinal 只做 HTTP / 插件 / Queue。
>
> **版本**：zent **v0.29.4+** · ZFinal **v0.21.0+** · Zig ≥ 0.17
> **参考实现**：[`examples/zent-shop`](../examples/zent-shop/)（9 实体完整可跑）

相关：[zent.md](zent.md)（定位/选型）· [architecture_best_practices.md](architecture_best_practices.md)（分层）·
[outbox.md](outbox.md)（事务 Outbox）· [scale_to_millions.md](scale_to_millions.md)（扩展）

---

## 1. 为什么要 zent 主力（而不是裸 JOIN 的 zf Model）

| 商城/社交痛点 | zf Model（SQL 栈） | zent（Schema-as-code） |
|---------------|--------------------|------------------------|
| 订单图/关注图/M2M/自引用 | 勉强 JOIN，手写关联 | **edge + QueryEdge + graph 遍历一等公民** |
| 行级权限（订单本人可见） | 手写 WHERE 拼接 | **`privacy/data_scope` 自动注入行级谓词** |
| 生命周期（下单扣库存、订单号生成） | 手写 | **runtime hooks（before/after）** |
| 防重（关注/点赞/购物车唯一） | 手写唯一校验 | **`field.Unique()` + 生成器自动防重** |
| 字段校验（邮箱/正数/必填） | 手写 validate | **`Email()/Positive()/NotEmpty()` 链** |
| 事务（下单 = 订单+扣库存+清购物车） | 手写 begin/commit | **`TxClient`（beginTx/commit/rollback/事件）** |

经验法则：**图关系密 + 有权限/生命周期诉求 → zent 主力**。本指南假设整站以 zent 为主力，
`zfinal.DB` 只留给旁路报表/遗留模块。

---

## 2. 领域建模（schema.zent 真源）

`examples/zent-shop/schema.zent` 是 9 实体范例。要点：

```
entity User {
  name: string @required            # → field.String("name").NotEmpty()
  handle: string @unique @index     # → .Unique()；生成 findByUniqueHandle + create 防重
  email: string @email @unique      # → .Email().Unique()
}

entity Product {
  seller_id: int                    # FK 字段（保持简单；复杂关系再上 edge）
  price_cents: int @positive        # → .Positive()
  stock: int = 0 @positive
  list_by: seller_id                # 生成 GET list + Query Where
}

entity Follow { follower_id: int; followee_id: int; list_by: follower_id }
entity Like    { user_id: int; post_id: int; list_by: post_id }
```

### 2.1 约束 DSL（`zf crud:zent` 生成器，v0.21.0+）

| DSL 修饰符 | 生成的 zent 代码 | 生成器附带产物 |
|-----------|-----------------|----------------|
| `@index` | `.indexes = Fields(&.{"col"})` | — |
| `@unique` | `field.X("col").Unique()` | `store.findByUnique<Col>` + service create `error.Duplicate` 防重 |
| `@sensitive` | `.Sensitive()` | 配合 `zent.codegen.entity.toMaskedJson` 脱敏输出 |
| `@required` | `.NotEmpty()`（string/text） | service 空值校验 |
| `@email` | `.Email()` | — |
| `@positive` | `.Positive()`（int/float） | — |
| `= default` | `.Default("...")` | handler 用 `getParaToLongDefault` |

字段类型：`string` / `text` / `int` / `bool` / `float` / `time` / **`uuid`** / **`bytes`** / **`enum(a,b,c)`**（→ `field.Enum(name, &.{"a","b","c"})`）。
JSON 版 schema 同样支持（`{"unique": true, ...}`，见 `examples/zent-shop/schema.json`）。

**组合唯一**（`unique: a, b` 实体级）：生成 `store.findUnique<Ent>(a, b)` + create 防重 `error.Duplicate`：

```
entity Follow {
  follower_id: int
  followee_id: int
  unique: follower_id, followee_id   # → findUniqueFollow + create 防重
}
```

**分页**：所有 `list_by` 列表自动支持 `?page=&size=`（`Limit/Offset`，newest-first；`size=0` = 全部）。
HTTP 响应统一带 `meta:{total, page, size}`（total 来自 `Count`）：

```
GET /api/v1/products?seller_id=1&page=2&size=10
→ { "ok": true, "products": [...], "meta": { "total": 37, "page": 2, "size": 10 } }
```

契约：`items`（字段名随实体，如 products/orders）为当前页数组；`meta.total` 为
满足过滤条件的总行数；`page` 从 1 开始；`size=0` 时返回全部行且 `total` 仍准确。

### 2.2 关系 DSL（`ref:` → zent edges + QueryEdge）

```
entity Post {
  author_id: int
  ref: author: User via author_id     # → edge.From("author", User).Field("author_id")
  list_by: author_id
}
```

- FK 列由 zent `addEdgeFields` 从 edge **自动生成**（`<edge>_id`），生成器在
  model.zig 中跳过被 `ref:` 引用的字段，避免重复列。
- 生成代码（create/list/findByUnique/update/delete）对 optional FK 自动 `orelse 0`。
- 密集关系图（≥6 实体）需要把 graph 解析 quota 提到 `@setEvalBranchQuota`：
  生成器已内置 `zentBuildGraph` wrapper，`migrateSchema` 同理（见
  `examples/zent-shop/src/main.zig`）。
- 批量加载：`client.<source>.QueryEdge("<edge>", ids)` 一次查询取目标实体（无 N+1），
  feed 示例见 `examples/zent-shop`（`feedFor`）。
- 图遍历（二级关注/好友推荐）：用 Follow 行做 2-hop 查询即可（`recommendFor` 示例），
  或 zent `graph/neighbors` 底层 builder。
- **反向 To / M2M edges**（`ref:` 只生成 From 方向）：在 `model.zig` 的
  `ai-edit-zone: model hooks` 手写补充：
  ```zig
  // To edge：target 持有 FK 指回本实体（O2M）
  .edges = &.{ zent.core.edge.To("posts", Post).Field("author_id") },
  // M2M 经过 junction（Through）：User ↔ Tag via user_tags
  .edges = &.{ zent.core.edge.To("tags", Tag).Through(UserTag) },
  ```
  声明后 `QueryEdge` / `OrderByEdgeCount` 可用。
- **`@sensitive` 脱敏输出**：生成 `.Sensitive()`；API 输出前用
  `zent.codegen.entity.toMaskedJson`（或手写 mask）替换敏感字段，示例见
  `doc/migration.md` 的绑定信封一节。
- **EntQL `has(edge)` / `not_has`（zent v0.28+）**：EXISTS 子查询做关系过滤，
  `QueryBuilder.WhereEntQL("has('posts', author_id = ?)", ...)` 或
  `has('followers')`（有任一关联）—— 比手写 `WhereIn` 子查询更声明式：
  ```zig
  // 只查有评论的帖子 / 只查被关注过的用户
  _ = try q.WhereEntQL("has('comments')", &.{});
  _ = try q.WhereEntQL("not_has('followers')", &.{});
  ```
- **操作级 privacy（zent v0.28+）**：`OnCreate`/`OnUpdate`/`OnDelete`/`OnQuery`
  只拦截对应操作（v0.27 是全操作 deny）—— 按需组合：
  ```zig
  // 查询可公开、写需鉴权：挂 OnCreate/OnUpdate/OnDelete
  .policy = .{ .rules = &.{ zent.privacy.OnCreate, zent.privacy.OnUpdate, zent.privacy.OnDelete } },
  ```

### 2.3 行级权限（`policy: data_scope`）

```
entity Order {
  buyer_id: int
  policy: data_scope                # → .policy = zent.data_scope.Policy
}
```

- 挂 policy 后该实体**所有操作必须带 PrivacyContext**：生成器默认给 create/list/
  update/delete/findByUnique 挂空 context（`.{}` → scope 不限制）；生产应传请求级
  `DataScopeFilter`：
  ```zig
  var scope = zent.data_scope.DataScopeFilter.init("dept_id", "buyer_id", .self_, .{ .user_id = uid });
  const scoped = client.order.withContext(scope.context(.{ .user_id = uid }));
  // scoped.Query() ... 自动注入 buyer_id = uid 谓词
  ```
- 示例：`examples/zent-shop` 的 `/api/v1/orders/mine`（`listOrdersScoped`）。

### 2.4 组合唯一（DSL `unique: a, b` 优先；手写兜底）

Follow/Like 的 `(a_id, b_id)` 组合唯一现在用实体级 `unique:` 声明自动生成
`store.findUnique<Ent>` + create 防重（见 §2.1）。旧的手写模式（persistence
custom queries 的 `findFollowPair` + service business rules 的 Duplicate）仍
兼容，两者任选其一，不要重复接线。

```zig
// persistence.zig  ── ai-edit-zone: custom queries
pub fn findFollowPair(self: *@This(), follower_id: i64, followee_id: i64) !?i64 {
    var q = self.client.follow.Query();
    defer q.deinit();
    const preds = self.client.follow.predicates;
    _ = try q.Where(.{ preds.follower_idEQ(.{ .int = follower_id }), preds.followee_idEQ(.{ .int = followee_id }) });
    var found = try q.All();
    defer { for (found.items) |*f| zent.codegen.deinitEntity(infos, FollowInfo, f, self.allocator); found.deinit(); }
    if (found.items.len == 0) return null;
    return found.items[0].id;
}

// service.zig  ── ai-edit-zone: business rules（生成器保留此区）
if (try self.store.findFollowPair(follower_id, followee_id) != null) return error.Duplicate;
```

---

## 3. 事务边界：下单模式（TxClient）

**规则**：一个事务只用一套驱动（zent 或 zfinal.DB）；写路径在 service，不在 handler 开长事务。

下单 = 读购物车 → 校验/快照价格 → 建 Order → 逐项扣库存 + 建 OrderItem → 清购物车 →
`commit`。zent 0.27 的 `TxClient` 一次搞定：

```zig
// persistence.zig  ── ai-edit-zone: custom queries
var txc = try zent.codegen.client.beginTx(infos, self.client);
defer txc.deinit();
errdefer txc.rollback() catch {};

// 事务内一律用 txc.client（同一连接），普通 store 方法仍可用
var q = txc.client.cart_item.Query();            // 读购物车（事务内）
_ = try q.Where(.{txc.client.cart_item.predicates.user_idEQ(.{ .int = user_id })});

var ob = try txc.client.order.Create();          // 建订单
_ = try ob.setFieldValue("buyer_id", user_id);
_ = try ob.setFieldValue("status", "pending");
const order_id = (try ob.Save()).id;

var ub = txc.client.product.Update();            // 原子扣库存（防超卖）
_ = try ub.Where(.{txc.client.product.predicates.idEQ(.{ .int = pid })});
_ = try ub.setExprArgs("stock", "stock - ?", &.{.{ .int = qty }});
_ = try ub.Save();

var db = try txc.client.cart_item.BulkDelete();  // 清购物车
_ = try db.Where(.{txc.client.cart_item.predicates.user_idEQ(.{ .int = user_id })});
_ = try db.Exec();

try txc.commit();                                // 出错 → errdefer rollback，无脏数据
```

要点：
- `setExprArgs("stock", "stock - ?")` 是**数据库原子扣减**，配合前置 `stock >= qty` 校验
  可防并发超卖；更高要求用 `WHERE stock >= ?` 的更新谓词 + `Save` 返回值判断。
- TxClient 还有 `afterCommit(ctx, cb)`（提交后回调：缓存失效/发通知）与
  `enqueueEvent(payload)`（事务事件 → `takePendingEvents`，配合
  [zent.outbox](https://github.com/chy3xyz/zent) 或 zfinal `DbOutbox`）。
- 事务内 `self.getProductById(...)`（普通 store 方法，同连接）读没问题；**写必须走 txc.client**。

---

## 4. 行级权限（订单本人可见）—— zent `privacy/data_scope`

zent 0.27 的 `privacy/data_scope` 是 RBAC 风格行级安全（all / self_ / dept_only /
dept_and_child / dept_custom），Schema 挂 policy，请求级 `DataScopeFilter` 自动注入
行级谓词，**不需要手写 WHERE**：

```zig
const doc = Schema("Order", .{
    .fields = &.{ field.Int("buyer_id"), field.Int("dept_id"), field.Int("total_cents") },
    .policy = zent.privacy.data_scope.Policy,   // 要求每请求带 scope
});
// 每请求：
var scope = zent.privacy.data_scope.DataScopeFilter.init("dept_id", "buyer_id", .self_, .{ .user_id = uid });
const client = store.client.withContext(scope.context(.{ .user_id = uid }));
// client.order.Query() ... 自动只返回本人/本部门订单
```

对商城（订单只属于买家）、社交（动态可见性/隐私设置）是现成能力，不必自研权限拼接。

---

## 5. 完整 CRUD + 生命周期 hooks

`zf crud:zent` 每个实体生成 **create / update / delete**（+ `list_by` 时 list）：

```
POST   /api/v1/products            # create
PUT    /api/v1/products?id=1       # update（query 传 id + 全部字段）
DELETE /api/v1/products?id=1       # delete
GET    /api/v1/products?seller_id= # list
```

- update/delete 生成在**编辑区外**（纯样板，避免同名 zone 顺序错位），业务校验
  加在 service 的 `ai-edit-zone`。
- **分页/排序**：zent `Query().OrderBy(&.{.{ .column = .{ .name = "id", .desc = true } }}).Limit(n).Offset((page-1)*size)`，
  示例见 `feedFor`（OrderBy+Limit）。
- **脱敏输出**：`@sensitive` 字段生成 `.Sensitive()`，用
  `zent.codegen.entity.toMaskedJson`（或手写 mask）在 handler 输出前脱敏。
- **hooks**：生成器在 `persistence.zig` 的 `init` 留了 hook-wiring 编辑区；
  在 custom queries zone 写回调（签名 `fn(ctx: *zent.runtime.hook.HookContext) zent.runtime.hook.HookError!void`），
  然后 `var client = ...` + `client.order = client.order.withHooks(&.{.{ .op = .create, .before = fn }});`
  （示例 `orderBeforeCreate`）。事务事件用 `TxClient.enqueueEvent` + `takePendingEvents`
  配合 `zent.outbox` 或 zfinal `DbOutbox`。

## 6. 关注图 / Feed / 关系查询

- **基础**：`list_by` 生成 `GET /follows?follower_id=`、`GET /posts?author_id=`。
- **边查询**：zent 0.27 `QueryEdge(edge_name, parent_ids)` 一次取多行关联（如批量取
  帖子作者昵称），比 N+1 查询好。
- **图遍历**：`zent.graph.step` / `neighbors` 支持 BFS（二级关注/好友推荐）。Schema 里
  声明 `edge.To/From` 后可用：

```zig
// model.zig  ── ai-edit-zone: model hooks
const Post = Schema("Post", .{
    .fields = &.{ field.Int("author_id"), field.Text("body") },
    .edges = &.{ zent.core.edge.To("author", User).Field("author_id") },
});
```

- **Feed 事件**：zent `crud.CrudService` 发布 `CrudEvent{created,updated,deleted}`，
  订阅后写 feed 表/推队列，避免读时 JOIN 关注表。

---

## 7. 与生成器协作（ai-edit-zone 契约）

```
schema.zent ──zf crud:zent --json──▶ model/persistence/service/handler/actions/routes
                ▲ 只改 // ── ai-edit-zone 区（重新生成自动保留、按出现顺序配对）
```

| 步骤 | 命令 |
|------|------|
| 生成/重新生成 | `zf crud:zent schema.zent`（**不带 --force**，保留手写 zone） |
| 重置一切 | `zf crud:zent schema.zent --force`（丢弃所有手写，慎用） |
| 加自定义路由 | `handler.zig` extra handlers 写函数 → `actions.zig` extra actions 加行 → `zf routes` |
| 校验 | `zf check && zig build test` |

**常见陷阱**
- `--force` 会**覆盖所有 ai-edit-zone**（含手写业务逻辑）—— 默认不传。
- 同名 zone（每个 createX 一个 `business rules`）在 v0.21.0 起**按出现顺序配对**；
  早期版本会错配，升级后重新生成一次即可纠正。
- 路由路径是 snake_case（`/api/v1/cart_items`），由实体名 `CartItem` 推导。
- `routes.zig` 标着 DO NOT EDIT；改路由走 actions.zig + `zf routes`。

---

## 8. 反模式

- 在 handler 里直接 `zent.sql_sqlite.open` 或混 `zfinal.DB.begin` 与 zent Tx —— 一个事务一套驱动。
- 把 zent entity 指针存进 Session 跨请求；忘记 `deinitEntity` / builder `deinit`。
- 图关系密却硬用 SQL JOIN 凑合；应声明 edge / 用 QueryEdge / graph。
- 手写 WHERE 做行级权限；应挂 `data_scope.Policy`。
- `--force` 重新生成覆盖手写业务逻辑。

---

## 9. 检查清单

- [ ] 主力数据层已明确：本系统/模块 = zent（`zfinal.zent`），`zfinal.DB` 仅旁路
- [ ] `schema.zent` 为真源；约束用 `@unique/@sensitive/@required/@email/@positive`
- [ ] 组合唯一在 ai-edit-zone 手写（findXxxPair + Duplicate）
- [ ] 下单等写路径在 service，用 `TxClient` 单事务（扣库存用 `setExprArgs` 原子式）
- [ ] 行级权限挂 `data_scope.Policy`；HTTP 只见 DTO
- [ ] 自定义路由走 handler extra handlers + actions + `zf routes`
- [ ] `zf check && zig build test` 通过；重新生成不带 `--force`

## 参考

- [`examples/zent-shop`](../examples/zent-shop/) —— 可运行的 9 实体参考实现（本指南同源）
- [`doc/zent.md`](zent.md) —— zent 定位、选型、反模式
- [chy3xyz/zent](https://github.com/chy3xyz/zent) —— v0.29.4 API（core/edge、privacy/data_scope、codegen/client、crud、outbox、shard）
