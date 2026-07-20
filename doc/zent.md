# ZFinal × zent：`DB` 的并列方案（可作主力）— **AI-first**

**zent**: [chy3xyz/zent](https://github.com/chy3xyz/zent) — Zig 版 [ent](https://entgo.io/)（schema-as-code ORM）  
**版本口径**: zent **v0.12.0+** · ZFinal **v0.13.11+** · Zig **≥ 0.17**  
**参考实现**: [`examples/zent-shop/`](../examples/zent-shop/)  
**决策**: [ADR-007](../.life/decisions/007-zent-peer-data-layer.md)  
**AI skill**: [`.claude/skills/zfinal-zent-ai.md`](../.claude/skills/zfinal-zent-ai.md)

相关：[ai-quickstart.md](ai-quickstart.md) · [architecture_best_practices.md](architecture_best_practices.md)

---

## 0. AI 开发契约（与 `crud:sql` 同级）

| 步骤 | 命令 / API |
|------|------------|
| 1. Schema 为真源 | `schema.zent` 或 `schema.json` |
| 2. 生成 + manifest | **`zf crud:zent <file> --json`**（Agent 必带 `--json`） |
| 3. 只改编辑区 | `// ── ai-edit-zone: …`（model / persistence / service / handler） |
| 4. 进程内工具 | `zfinal.aichat.ZfTool.manifestFromZent` / `buildAgentSystemPromptZent` |
| 5. 校验 | `zf check && zig build test` |

```bash
zf crud:zent examples/zent-shop/schema.zent --json --explain
```

`--json` 含 `files`、`ai_edit_zones[]`（file/markers/purpose）、`entities`、`next_steps`。  
**禁止**手写 Schema/Client 样板；**禁止**同一事务混用 `zfinal.DB` 与 zent Driver。

---

## 1. 定位：与 `DB` / `Model` 二选一（或按模块选型）

ZFinal 提供 **两套同级数据层**，不是「zent 挂在 DB 下面」：

| 方案 | 导出 | 适合作为**全站主力**的场景 |
|------|------|---------------------------|
| **A. SQL 栈** | `zfinal.DB` / `Model` | 表结构平、CRUD 为主、已有 SQL、走 `zf crud:sql` |
| **B. zent 栈** | `zfinal.zent` | 关系图密、要 privacy/hooks — **电商 / 社交 / 权限图** |

`examples/zent-shop` 演示的是：**整站以 zent 为主力**，HTTP / Queue / 插件仍用 ZFinal。

```zig
const zfinal = @import("zfinal");

// —— 方案 A：主力 = DB ——
var db = try zfinal.DB.open(...);
const User = zfinal.Model(UserRow);

// —— 方案 B：主力 = zent ——
const zent = zfinal.zent;
var drv = try zent.sql_sqlite.SQLiteDriver.open(allocator, "app.db");
```

构建开关：

```bash
zig build                      # -Denable-zent=true（默认，可作主力）
zig build -Denable-zent=false  # 只要 SQL 栈时的瘦构建
```

**禁止**把 `zent` Driver 塞进 `zfinal.DB` / `ConnectionPool`。两套池、方言、迁移各自管理。

```
ZFinal (HTTP / plugins)          ← 始终同一套
        │
        ├─ 选主力数据层（二选一，或按模块拆）
        │
   ┌────┴────┐
   ▼         ▼
 DB/Model   zent          ← 同级备选；可整站只选一边
 (zf SQL)   (Schema)
```

---

## 2. 怎么选主力？

| 问题 | 偏 A（`DB`） | 偏 B（`zent` 作主力） |
|------|--------------|----------------------|
| 从 SQL / 存量表起步？ | ✅ | 可选迁移后用 zent |
| AI 流水线 `zf crud:sql`？ | ✅ 默认 | ❌ 手写 Schema（或未来 emitter） |
| 订单图 / 关注图 / M2M / 自引用？ | 勉强 JOIN | ✅ **推荐主力** |
| 行级 privacy、生命周期 hooks？ | 自写 | ✅ 一等公民 |
| 简单博客 / 后台 CRUD？ | ✅ | 过重 |

**经验法则**

- 新做 **电商 / 社交 / 复杂 RBAC**：默认 **zent 作主力**，`DB` 仅留给旁路报表或遗留模块。
- 新做 **CRUD 后台 / SQL 已定稿**：默认 **`DB` + `zf`**。
- 同进程混用：只按 **模块** 拆，跨域用 Queue，不指望跨栈同事务。

---

## 3. 模块级混合（可选）

```
ZFinal HTTP
     │
┌────┴────┐
│         │
catalog  blog/posts
(zent    (zf Model)
 主力)    旁路)
```

| 可以 | 不行 |
|------|------|
| 主域 zent、次域 `DB` | 同一事务混两套驱动 |
| 各自 migrate / 连接池 | 把 zent Driver 塞进 `zfinal.DB` |
| service 只交换 DTO | 跨栈指望同一 DB 事务 |

跨域副作用：`QueueRobustMQClient` / `QueueNatsClient` / 进程内 `QueueClient`。

---

## 4. 以 zent 为主力时的分层

仍对齐 ZFinal 三层，只是 persistence 换成 zent：

```
src/modules/<domain>/
  model.zig         # zent Schema（不是 zf Model）
  persistence.zig   # Client / migrate / DTO
  service.zig       # 业务
  handler.zig       # HTTP；不碰 sql_*
```

依赖：`handler → service → persistence → zfinal.zent`。

参考：`examples/zent-shop`。

---

## 5. 启动流水线（zent 主力）

```
open SQLite/PG (zent driver)
  → migrateSchema(infos)
  → makeClient / Store.init
  → inject service → register routes
  → ZFinal.start()
```

生产用 `zent.sql_pool.ConnPool`；不要每请求 `open`。

---

## 6. 依赖与运行

核心 `build.zig.zon` 已声明 zent；应用：

```zig
const zent = @import("zfinal").zent;
```

```bash
cd examples/zent-shop && zig build run
zig build run-zent-shop
```

---

## 7. 反模式

- 在 handler 里直接 `zent.sql_sqlite.open`
- 同一请求混 `zfinal.DB.begin` 与 `zent` Tx
- 把 zent entity 指针存进 Session 跨请求
- 忘记 `deinitEntity` / builder `deinit`
- 明明图关系密却硬用 `zf` JOIN「凑合」——应改以 **zent 作主力**
- 为「统一」强行把两套驱动绑进同一连接池

---

## 8. 检查清单

- [ ] 已明确本应用/本模块的**主力**是 `DB` 还是 `zent`
- [ ] 使用 `zfinal.zent`（或确认 `-Denable-zent=true`）
- [ ] Schema 在 `model.zig`；SQL 不出 persistence
- [ ] HTTP 只见 DTO；migrate 在 listen 前完成
- [ ] 异步副作用走 Queue 插件

---

## 9. 与 AI / `zf` 的关系

| 流程 | 工具 |
|------|------|
| SQL → CRUD 模块（主力 = DB） | `zf crud:sql schema.sql --json` |
| **zent Schema → 模块（主力 = zent）** | **`zf crud:zent schema.zent --json`** |
| 图关系密的新域（手写微调） | 生成后改 `ai-edit-zone`（见 zent-shop） |

```bash
# 与 crud:sql 对称
zf crud:zent examples/zent-shop/schema.zent --json
# 或 JSON：
zf crud:zent examples/zent-shop/schema.json --force

# 产出
# src/modules/<module>/{model,persistence,service,handler,routes}.zig
```

`.zent` DSL 摘要：

```
module shop
api_prefix /api/v1

entity Product {
  seller_id: int
  name: string
  stock: int = 0
  list_by: seller_id   # 生成 GET list + Query Where
}
```

字段类型：`string` / `text` / `int` / `bool` / `float` / `time`；修饰 `@index`、`= default`。

Agent：电商/社交优先 **`zf crud:zent`**，不要默认拆成一堆裸 JOIN 的 `zf` Model。

---

## 10. 生产成熟度 / 事务边界 / SLA

| 级别 | 何时可用 |
|------|----------|
| Demo / AI codegen | `examples/zent-shop` + `zf crud:zent` — **可用** |
| 受控生产（单库、池化） | `ConnPool`、migrate 在 listen 前、压测通过 — **可用** |
| 硬 SLA / 多区域 | 需自建备份、迁移演练、故障注入 — **bake 后再承诺** |

**事务边界（硬规则）**

1. 同一事务只使用 **一个** zent Driver/Client（或只使用 `zfinal.DB`）— 禁止混用。
2. 跨模块副作用走 Queue（NATS / 进程内），不要指望跨库 2PC。
3. HTTP 层只见 DTO；写路径在 service，不在 handler 开长事务。

交叉引用：[`PRODUCTION_AUDIT.md`](../PRODUCTION_AUDIT.md) · [`examples/zent-shop`](../examples/zent-shop/) · [ADR-007](../.life/decisions/007-zent-peer-data-layer.md)。
