# ADR-017 新特性性能评估

> 测量环境：macOS aarch64 · Zig 0.17.0-dev · `ReleaseFast` · 内存 SQLite
> 数据：`posts` 表 5,000 行（pub/draft 交替，无索引）
> 复现：`zig build run-adr017-bench`（`benchmark/adr017_bench.zig`）

## 结论摘要

**框架层新增开销可忽略（纳秒～微秒级）；真正的成本在 SQL 执行，且只出现在无索引过滤/排序/唯一性检查时。** 新 API 相比手写代码没有性能倒退，声明式写法是免费的。

## 数字

| 路径 | ns/op | 说明 |
|------|-------|------|
| `Model.paginate`（基线，无过滤） | 12,840 | COUNT + LIMIT 20 |
| `Query.paginate`（无过滤，纯构建器） | 12,500 | ≈ 基线 → **构建器开销 ≈ 0** |
| `Query.paginate`（eq + orderBy，命中 2,500 行） | 471,455 | 差异 = SQLite 无索引扫描 + 排序 2,500 行 |
| `Query.list`（likeAll OR 2 列，命中 2,500 行） | 1,139,270 | 差异 = 无索引 LIKE 全表扫 |
| `validateUnique`（0 命中 SELECT） | 162,780 | 一次额外 SELECT；无索引时全表扫 |
| `bindStruct`（5 字段声明式绑定） | 7 | comptime 循环，零分配 |
| `bindJsonInto`（5 字段 JSON → arena） | 290 | JSON 解析本身 |
| `toView`（3 字段借用投影） | ~0 | 纯结构体拷贝 |

## 逐项解读

1. **`Model.Query` 构建器**：SQL 拼装 + 参数收集全部发生在请求作用域，与旧的 `findWhere` 手拼路径同量级；隔离测量显示与基线**无差异**。comptime 列名校验是编译期成本，运行时为零。
2. **过滤/排序的 30~90 倍差距是 SQL 不是框架**：无索引的 `WHERE status='pub' ORDER BY views DESC` 在 SQLite 里要扫 + 排 2,500 行。同样的 SQL 手写也一样慢。**PG/MySQL 走索引时是毫秒→微秒级。**
3. **`validateUnique` 是刻意的每请求一次额外 SELECT**：这是 `@unique` 语义的代价（插入/更新前查重）。无索引时 163µs；给 `@unique` 列建唯一索引后降到 µs 级，且 DB 层的唯一约束本就是最终防线。
4. **DTO 绑定与投影**（`bindStruct` 7ns、`bindJsonInto` 290ns、`toView` ~0）相对任何网络/DB 往返都可忽略。
5. **`renderPage` / `ok` / `created`**：一次 JSON 序列化 + 释放，与手写 `renderJson` 等价，无额外成本。

## 生产建议（schema 层，非框架层）

- 给 `@filter` / `@sortable` 的高频列建索引（如 `status`、`created_at`）。
- 给 `@unique` 列建**唯一索引**（既有约束又能让 `validateUnique` 走索引）。
- 多列过滤/排序的常见组合建复合索引。
- 后续增强（可选）：`zf crud` 依据注解在 `schema.gen.sql` 里自动补 `CREATE INDEX`，把“索引跟着过滤注解走”也变成声明式。

## 一句话

声明式列表查询 / DTO / 校验 / 投影**没有引入性能税**；把注意力放在 schema 索引上即可。
