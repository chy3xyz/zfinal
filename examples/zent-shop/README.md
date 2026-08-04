# zent-shop — ZFinal + zent（电商 + 社交，zent v0.27 主力）

用 **[zent](https://github.com/chy3xyz/zent)** v0.27.0 做 schema-as-code 数据层（可作全站主力），用 **ZFinal** 做 HTTP / 插件层。

指南：[doc/zent.md](../../doc/zent.md) · [doc/zent-commerce-social.md](../../doc/zent-commerce-social.md)

## 领域模型（9 实体，schema.zent 为真源）

```
电商:  User · Product · CartItem · Order · OrderItem
社交:  Follow（关注） · Like（点赞） · Post（动态） · Comment（评论）
```

`schema.zent` 字段约束（`zf crud:zent` 生成器 DSL 增强）：

```
name: string @required        → field.String("name").NotEmpty()
handle: string @unique @index → field.String("handle").Unique()
email: string @email @unique  → field.String("email").Email().Unique()
price_cents: int @positive    → field.Int("price_cents").Positive()
stock: int = 0 @positive      → field.Int("stock").Default("0").Positive()
```

- `@unique` 自动生成 `store.findByUnique<Field>` + service create 防重（`error.Duplicate`）
- 组合唯一（Follow/Like 的 (a_id, b_id)）在 `ai-edit-zone` 手写 `findFollowPair` / `findLikePair`

## 运行

```bash
cd examples/zent-shop
HTTP_PORT=18200 zig build run
```

或仓库根：`zig build run-zent-shop`。

## Smoke（curl）

```bash
B=http://127.0.0.1:18200

# 用户（email/handle 唯一，重复 → {"ok":false,"error_msg":"Duplicate"})
curl -s -X POST "$B/api/v1/users?name=Alice&handle=alice&email=a@x.com"
curl -s -X POST "$B/api/v1/users?name=Bob&handle=bob&email=b@x.com"

# 电商：上架 + 加购 + 事务下单
curl -s -X POST "$B/api/v1/products?seller_id=1&name=Widget&price_cents=1999&stock=10"
curl -s -X POST "$B/api/v1/products?seller_id=1&name=Gadget&price_cents=999&stock=3"
curl -s -X POST "$B/api/v1/cart_items?user_id=2&product_id=1&qty=2"
curl -s -X POST "$B/api/v1/cart_items?user_id=2&product_id=2&qty=1"
curl -s -X POST "$B/api/v1/orders/checkout?user_id=2"
#   → {"ok":true,"order_id":1}；库存 10→8、3→2；购物车清空；OrderItem 快照价格
#   库存不足 → {"ok":false,"error_msg":"InsufficientStock"}，整单回滚（无脏数据）

# 社交：动态/评论 + 关注/点赞防重
curl -s -X POST "$B/api/v1/posts?author_id=2&body=hello-social"
curl -s -X POST "$B/api/v1/comments?post_id=1&author_id=1&body=nice!"
curl -s -X POST "$B/api/v1/follows?follower_id=1&followee_id=2"
curl -s -X POST "$B/api/v1/follows?follower_id=1&followee_id=2"   # → Duplicate
curl -s -X POST "$B/api/v1/likes?user_id=1&post_id=1"
curl -s -X POST "$B/api/v1/likes?user_id=1&post_id=1"             # → Duplicate

# 关系：feed（QueryEdge 批量作者加载）+ 好友推荐（2-hop）
curl -s "$B/api/v1/feed?user_id=1&limit=5"         # 关注的作者动态，含 author_handle
curl -s "$B/api/v1/recommend?user_id=1&limit=5"    # 二级关注（好友推荐）

# 完整 CRUD：update / delete
curl -s -X PUT "$B/api/v1/products?id=1&seller_id=1&name=WidgetPro&price_cents=2500&stock=8"
curl -s -X DELETE "$B/api/v1/products?id=2"

# 行级权限（data_scope）：只看到自己的订单
curl -s "$B/api/v1/orders/mine?user_id=2"
```

## 关键实现（全部在 `ai-edit-zone` 内手写，重新生成自动保留）

| 能力 | 文件 / zone | 说明 |
|------|------------|------|
| 事务下单 | `persistence.zig` custom queries | `zent.codegen.client.beginTx` → 校验库存 + 建 Order/OrderItem + `setExprArgs("stock","stock - ?")` 扣库存 + BulkDelete 清购物车 → `commit`；错误 `rollback` |
| 组合唯一防重 | `persistence.zig` + `service.zig` business rules | `findFollowPair` / `findLikePair`（多谓词 Where） |
| 自定义路由 | `handler.zig` extra handlers + `actions.zig` extra actions | 加 handler 函数 → actions 表加行 → `zf routes` |

## 布局

```
src/
  main.zig                 # ZFinal + zent migrate + routes.register
  modules/shop/
    schema.zent            # （仓库根 examples/zent-shop/schema.zent）真源
    model.zig              # 9 个 zent Schema（约束链由生成器产出）
    persistence.zig        # zent Client → DTO；TxClient 下单事务
    service.zig            # 业务校验 / 防重 / checkout
    handler.zig            # HTTP；不 import zent.sql_*
    actions.zig            # 动作表（extra actions 追加自定义路由）
    routes.zig             # zf routes 生成，勿手改
```

**不要**把 `zent.Driver` 混进 `zfinal.DB`；同一事务只用 zent TxClient。
