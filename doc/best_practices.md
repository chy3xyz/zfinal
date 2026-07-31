# ZFinal 最佳实践总索

> **版本**：v0.20.10 · Zig `0.17.0-dev.1422+e863bf3be` · 修订 **2026-07-31**  
> **受众**：应用开发者、框架贡献者、AI agent  
> **验证基线**：`zig build gate`（或 `zig build test` → **263 passed; 11 skipped**）· `zig build test-zf`

本文是**最佳实践文档的入口**：按任务选文档，按版本看能力何时可用。细节仍在各专题文中。

---

## 1. 按任务选文档

| 你要… | 读 |
|-------|-----|
| 模块分层 / AI 边界 / 插件成熟度 | [architecture_best_practices.md](architecture_best_practices.md) |
| L0→L3 怎么长、何时抽 ports | [progressive_architecture.md](progressive_architecture.md) |
| 千万级拓扑与容量 | [scale_to_millions.md](scale_to_millions.md) |
| `actions.zig` / `zf routes` / 嵌套 / 尾通配 | [smart_routing.md](smart_routing.md) |
| State / Extension / extract / HttpError / stock | [http_ergonomics.md](http_ergonomics.md) |
| JSON 信封 REST vs zapi | [api_envelope.md](api_envelope.md) |
| 发布 / 质量门（`zig build gate`） | [release_and_quality_gates.md](release_and_quality_gates.md) |
| 模块市场（本地目录 phase 1） | [module_marketplace.md](module_marketplace.md) |
| 反代 + `force_connection_close` | [reverse_proxy.md](reverse_proxy.md) |
| 数据层 A `DB` / 数据层 B `zent` | [database.md](database.md) · [zent.md](zent.md) |
| 生产契约打分与清单 | [`PRODUCTION_AUDIT.md`](../PRODUCTION_AUDIT.md) |
| 安全默认值 | [`SECURITY.md`](../SECURITY.md) |
| Agent 硬规则 | [`AGENTS.md`](../AGENTS.md) · [ai-quickstart.md](ai-quickstart.md) |

---

## 2. 能力时间线（写代码时用）

以 **合并进 `main` 的能力** 为准。新项目按「当前行」写；读旧示例时对照版本。

| 时段 | 版本 | 写应用时默认采用 |
|------|------|------------------|
| 2026-07-31 | **0.20.10** | 产品化 `zig build gate` / `zf release-check --strict`；模块市场 phase 1（`zf market`） |
| 2026-07-31 | **0.20.9** | Smart routing（`actions.zig`）；Axum 风格 State/extract/`failHttp`；拦截器 **caller-owned `*const Cfg`**；OpenAPI 实体 DTO；信封默认 HttpError（见 ADR-013） |
| 2026-07-23 | 0.20.4–0.20.8 | `zf g port` + ports-l2/l3；zone merge regen；JWT RS256；RobustMQ rebalance；MQTT TLS；**保持** `force_connection_close=true`；idle/write timeout 真生效 |
| 2026-07-22 | 0.20.2–0.20.3 | `zf new` 远程依赖；migrate/seed 多驱动；`queryCached`（PG/MySQL） |
| 更早 0.13–0.19 | — | Fiber Server（ADR-001）、zent、NATS/RobustMQ 稳定面、Metrics 路由类等已落地；细节以 CHANGELOG 为准 |

### 仍未「默认打开」的（运维约束，不是弃用）

| 项 | 实践 |
|----|------|
| 应用侧 keep-alive | 生产 **保持** `force_connection_close=true`；客户端复用放反代（[reverse_proxy.md](reverse_proxy.md) §9；zig#25017） |
| zapi `{code,msg,data}` | **应用层**成败统一；框架默认不翻（[api_envelope.md](api_envelope.md)） |
| Zig 0.17 stable | 钉 CI 同款 `-dev`；升级跟 `build.zig.zon` / CI |

---

## 3. 绿场默认栈（2026-07 / v0.20.10）

一条「今天新建项目」的推荐路径：

```
schema.sql | schema.zent
    → zf crud:sql|zent --json
    → （可选）actions.zig + zf routes --json
    → 只改 ai-edit-zone；错误用 return error.* / failHttp
    → main：Metrics + RequestId + SecurityHeaders + JWT/CORS（caller-owned cfg）
    → force_connection_close=true + 反代 TLS
    → zf check [--prod] && zig build gate-quick
```

| 层 | 默认选择 |
|----|----------|
| 数据 | 平 CRUD → `DB`+`zf crud:sql`；图/电商 → `zent`+`zf crud:zent`（**一模块不混驱动**） |
| 路由 | 新模块优先 `actions.zig`；存量手写 `app.get` 可暂留，勿两套真源 |
| HTTP | `HttpError` + `extract.*`；需要 Axum 味再加 State/Extension/stock |
| 信封 | 公开 API → A（`err`/`msg`）；中式 BFF → B（zapi，成败同形） |
| 规模 | 先 L0/L1（`examples/production`）；多实例再 L2 ports；千万准备再 L3 |

---

## 4. 决策记录（ADR）速查

| ADR | 主题 |
|-----|------|
| 001 | Fiber Server（单一并发模型） |
| 002 | CSPRNG |
| 003–004 | experimental → stable 插件 |
| 011 | Smart routing |
| 012 | Axum-style HTTP ergonomics |
| 013 | JSON 信封默认保持 HttpError |
| 014 | 产品化质量 / 发布门 |
| 015 | 模块市场：本地目录优先 |

目录：[`.life/decisions/`](../.life/decisions/)。

---

## 5. 提交前最小清单

```bash
zf check                 # 应用仓；生产示例加 --prod
zig build gate-quick     # 或完整：zig build gate / zf gate
# 等价拆分：zig build && zig build test && zig build test-zf && zig fmt --check …
```

打 tag 前：`zf release-check`（见 [release_and_quality_gates.md](release_and_quality_gates.md)）。

生产额外：[`PRODUCTION_AUDIT.md`](../PRODUCTION_AUDIT.md) 部署契约 15 条 + [`benchmark/BASELINE.md`](../benchmark/BASELINE.md)。

---

## 6. 一句话

**按 v0.20.10 能力写：生成器定骨架，三层定方向，路由用 actions，错误用 HttpError，拦截器 cfg 自持有，规模按 L0→L3 只换装配；合并前走 `zig build gate`；keep-alive 与 zapi 默认不翻，用文档与 ADR 锁边界。**
