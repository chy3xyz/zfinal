# zent-shop — ZFinal + zent（电商目录 + 社交关注）

用 **[zent](https://github.com/chy3xyz/zent)** v0.12+ 做 schema-as-code 数据层，用 **ZFinal** 做 HTTP / 插件层。

指南：[doc/zent.md](../../doc/zent.md)

## 前置

```bash
# 期望目录
zig_ws/
  zfinal/
  zent/          # git clone https://github.com/chy3xyz/zent.git
```

`build.zig.zon` path 依赖 `../../../zent`。

## 运行

```bash
cd examples/zent-shop
HTTP_PORT=18200 zig build run
```

或仓库根（检测到 sibling zent 时）：

```bash
zig build run-zent-shop
```

## Smoke

```bash
curl -s http://127.0.0.1:18200/health

# 用户
curl -s -X POST 'http://127.0.0.1:18200/api/v1/users?name=Alice&handle=alice'
curl -s -X POST 'http://127.0.0.1:18200/api/v1/users?name=Bob&handle=bob'

# 电商：卖家上架
curl -s -X POST 'http://127.0.0.1:18200/api/v1/products?seller_id=1&name=Widget&price_cents=1999&stock=10'
curl -s 'http://127.0.0.1:18200/api/v1/products?seller_id=1'

# 社交：关注 + 动态
curl -s -X POST 'http://127.0.0.1:18200/api/v1/follows?follower_id=1&followee_id=2'
curl -s 'http://127.0.0.1:18200/api/v1/follows?follower_id=1'
curl -s -X POST 'http://127.0.0.1:18200/api/v1/posts?author_id=2&body=hello-social'
curl -s 'http://127.0.0.1:18200/api/v1/posts?author_id=2'
```

## 布局

```
src/
  main.zig                 # ZFinal + zent migrate
  modules/shop/
    model.zig              # User / Product / Follow / Post
    persistence.zig        # zent Client → DTO
    service.zig
    handler.zig            # 不 import zent.sql_*
```

**不要**把 `zent.Driver` 混进 `zfinal.DB`。
