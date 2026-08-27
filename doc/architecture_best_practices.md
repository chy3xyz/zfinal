# ZFinal 代码架构最佳实践

> **版本**：对齐 v0.20.9+ / Zig `0.17.0-dev.1422` · 修订 **2026-07-31**  
> **受众**：框架贡献者、应用开发者、AI agent  
> **总索**：[best_practices.md](best_practices.md)（任务索引 + 能力时间线）  
> **相关**：[`AGENTS.md`](../AGENTS.md) · [`PRODUCTION_AUDIT.md`](../PRODUCTION_AUDIT.md) · [`api_envelope.md`](api_envelope.md) · [`.life/decisions/`](../.life/decisions/)

核心原则：**Schema 驱动 + 三层分离 + AI 可编辑边界 + 稳定/实验 API 分级**。  
业务用 `zf` 生成，框架按目录职责生长，生产只碰稳定面。

**规模与 HTTP（专题）：**

- 容量与拓扑 → [scale_to_millions.md](scale_to_millions.md)
- L0→L3 渐进代码架构 → [progressive_architecture.md](progressive_architecture.md)
- 智能路由（`actions.zig` / 嵌套 / 尾通配）→ [smart_routing.md](smart_routing.md)
- Axum 风格 HTTP → [http_ergonomics.md](http_ergonomics.md)

---

## 1. 总览：两套架构不要混

| 层次 | 对象 | 怎么组织 |
|------|------|----------|
| **应用侧** | 业务代码 | `handler → service → model`，由 `zf crud:sql` 生成 |
| **框架侧** | `src/*` | `core / db / interceptor / plugin / kit / …`，按职责分包 |

```
HTTP 请求
  → InterceptorChain（横切：日志 / 鉴权 / CORS / CSRF）
  → Router → Handler（绑参、状态码、响应形状）
  → Service（业务规则、事务边界）
  → 数据层（二选一主力）：
       A) Model / DB（`zf crud:sql`）
       B) zfinal.zent（schema-as-code；电商/社交可作全站主力）
```

详见 [zent.md](zent.md)。

---

## 2. 应用模块：严格三层

```
src/modules/<sub>/<name>/
├── actions.zig   # （推荐，v0.20.9+）路由真源 → zf routes
├── handler.zig   # HTTP：解析、CSRF、限流、调用 service、渲染
├── service.zig   # 业务：校验、编排、事务意图
├── model.zig     # 数据：结构体、ORM、自定义查询
└── routes.zig    # 路由注册（薄；可由 zf routes 生成）
```

zent 模块另有 `persistence.zig`（见 [zent.md](zent.md)）。

### 实践

- **Handler** 不写 SQL、不做领域决策；只做 IO 边界；失败优先 `return error.*` / `failHttp`。
- **Service** 不碰原始 HTTP；不直接拼协议帧 / RESP。
- **Model** 不返回 HTTP 状态；只表达表与查询。
- **禁止从零手写** CRUD 四件套 → 使用 `zf crud:sql` / `zf crud:zent` / `zf g …`；改样板改 `tools/zf/`。
- **只改** `// ── ai-edit-zone: …`；区外交给生成器（同名 zone **merge**）。提交前跑 `zf check`。
- **路由真源**：绿场用 `actions.zig` + `zf routes`；禁止业务散落 `app.get/post` 与 actions 双真源（[smart_routing.md](smart_routing.md)）。

这是 ZFinal 相对「手写全栈」最大的架构约束，也是 AI 协作的契约。

---

## 3. AI-First 边界（架构一等公民）

```
SQL schema  ──zf──►  生成物 + JSON manifest
                      │
                      ├─ @generated 头
                      ├─ ai-edit-zone（唯一手写点）
                      └─ 再生成时保留 zone 内逻辑
```

### 实践

- Agent 固定流程：`schema → zf … --json → 只改 zone → zf check → zig build test`。
- 需要改「所有模块的样板」→ 改 codegen，不要批量手改生成文件。
- 公开 API 变更：同步 `src/main.zig`、生成器与文档。
- AI 调用 CLI 时一律加 `--json`，解析 manifest 而不是扫工作树。

详见：[ai-quickstart.md](ai-quickstart.md)、[codegen.md](codegen.md)。

---

## 4. 框架目录职责

| 目录 | 放什么 | 不放什么 |
|------|--------|----------|
| `core/` | Server、Router、Context、Session、Logger、Metrics、Shutdown | 业务实体 |
| `db/` | 连接、池、ORM、分页、驱动（PG/MySQL opt-in）— **数据层 A** | HTTP |
| （`zfinal.zent`） | schema-as-code ORM — **数据层 B**，可与 A 二选一作主力 | 与 `DB` 同事务混用 |
| `interceptor/` | 请求链横切 | 持久化 |
| `plugin/` | 可启停能力（Cache / Redis / Cron / MQTT / P2P…） | 无生命周期的纯函数 |
| `kit/` | **零框架依赖** 工具 | `@import("zfinal")` |
| `ext/` | 对 Context / Handler 的扩展（如可信代理 IP） | 新协议实现 |
| `validator/` / `token/` / `captcha/` | 安全与输入 | 业务规则散落 |
| `websocket/` / `template/` / `upload/` / `i18n/` | 专项子系统 | 通用杂项 |

### 实践

- 新「能力」先问：要不要 `Plugin.start/stop`？要 → `plugin/`；纯工具 → `kit/`。
- `kit` 保持无环依赖，方便单测与复用。
- 对外只从 `src/main.zig` 导出稳定符号；半成品进 `zfinal.experimental.*`。

---

## 5. 服务与并发（ADR-001）

- **单一 Fiber Server**（`Io.Threaded` + `Group.async`），不要再分 Sync / Async 两套。
- Fiber 返回值约束：`acceptLoop` 包一层 → `Cancelable!void`；真错误用 ErrorHandle 隔离，避免拖垮 accept 循环。
- 连接路径目标：**每连接尽量零堆**；业务分配用 `ctx.allocator`，请求结束释放（不要臆造 per-request Arena，除非框架已提供）。
- 跨线程与测试 IO：慎用依赖 futex 的 `std.Io.Mutex`；P2P 等场景用 `atomic.Mutex` + spin 是有意选择。
  生产 mesh 建议 `setHmacKey`（帧级 HMAC-SHA256），否则任意能连上端口的对端可注入 inbox。
- 池 / Session：`lockUncancelable`、**先 unlock 再 destroy**；禁止用 `@panic` 当错误处理。

ADR：[001-fiber-server.md](../.life/decisions/001-fiber-server.md)。

---

## 6. 数据与内存所有权

- **参数化 SQL**（`ParamQuery` / 绑定）；禁止字符串拼接用户输入。
- `*DB` 堆上 + magic / `checked_out`：防 UAF、防池归还后再用。
- `errdefer` 链成对：`dupe` / `append` / 打开资源必须有失败回滚路径。
- 驱动：**默认 SQLite 零额外依赖**；PG/MySQL 用 `-Ddriver_pg` / `-Ddriver_mysql` opt-in，生产单独验证。
- 事务：`begin` / `commit` / `rollback` 走 DB API；失败打日志并向上返回，不吞错。

详见：[database.md](database.md)、[db.md](db.md)。

---

## 7. 安全默认值

- 熵：安全路径用 **OS CSPRNG**，不用固定种子 PRNG（ADR-002）。
- Cookie：默认 HttpOnly + SameSite；Secure 显式开启。
- 客户端 IP：默认**不信任** `X-Forwarded-For`；仅在反代 + `trusted_proxies` 时打开。
- 路径：下载 / 静态走 sandbox；带 traversal 测试。
- CSRF / 限流挂在 Handler 或拦截器；生成 CRUD 已带常见钩子。
- **JSON 信封**：默认 REST/`HttpError`（`err`+`msg`+`detail?`）。中式 BFF 用 zapi
  `{code,msg,data}` 时须**成败统一**，禁止只改错误体。详见 [api_envelope.md](api_envelope.md)。

生产契约见 [`PRODUCTION_AUDIT.md`](../PRODUCTION_AUDIT.md)。

---

## 8. HTTP 响应与拦截器（摘要）

- 失败优先 `return error.NotFound`（等），由 `dispatch` → `http_error.render`；勿手搓错误 JSON。
- 生成 CRUD 用 `failHttp`；旧 handler：`zf check --heal`。
- 拦截器 cfg：**caller-owned** `*const Cfg`，禁止 `createX(&.{…})`（UAF）；`zf check` 会 WARN。
- 404/405/fallback 也会跑全局 `runAfter`（Trace / access_log）。
- App 级：`setState` / `ctx.ext` / `zfinal.stock.*` / `fallback`+`merge`（[http_ergonomics.md](http_ergonomics.md)）。
- Cache 拦截器是 **GET hit-only**；TCP 下 after-store 无效。
- Keep-alive：生产保持 `force_connection_close=true`（[reverse_proxy.md](reverse_proxy.md) §9）。

---

## 9. 插件成熟度模型

```
stub / 可选依赖  →  zfinal.experimental.*
有测试、无重依赖、可生产   →  zfinal.*（stable）
废弃路径：experimental 留 @deprecated 别名一段时间
```

### 实践

- 生产禁止无 ADR 地使用 `experimental`。
- 新插件：`init` / `deinit` +（可选）`Plugin` vtable + **同文件 `test`**，再进 `main.zig`。
- 例：`QueueClient`（内存）、`QueueNatsClient`（NATS）、`QueueRobustMQClient`（Kafka/RobustMQ）均为稳定零依赖（或系统库）实现。

ADR：[003-experimental-plugins.md](../.life/decisions/003-experimental-plugins.md)、[004-stable-plugins.md](../.life/decisions/004-stable-plugins.md)。

---

## 10. 可观测与运维契约

- Logger：结构化字段；级别 **编译期** `-Dlog-level`。
- Metrics + `healthHandlerFor`；优雅关闭走 `shutdown`。
- 部署：TLS 终止在反代；钉死与 CI 同款 Zig；ReleaseSafe smoke。
- **Keep-alive**：生产保持 `force_connection_close=true`；客户端复用交给 nginx/Caddy（见 [reverse_proxy.md](reverse_proxy.md)）。勿为压测在生产关掉该开关。
- 验证基线：

```bash
zig build
zig build test          # 期望：416 passed; 16 skipped; 0 failed
zig build test-zf
zig fmt --check src/ test/ tools/ examples/ benchmark/ build.zig
zf check                # 应用仓库
```

---

## 11. 场景速查

| 场景 | 最佳做法 |
|------|----------|
| 新表 / CRUD | `zf crud:sql` / `zf crud:zent` `--json` → 只改 ai-edit-zone |
| 新路由 / 嵌套资源 | `actions.zig` → `zf routes --json` |
| 新横切逻辑 | Interceptor（caller-owned cfg）或 Handler 包装，不塞进 Model |
| JSON 信封选型 | [api_envelope.md](api_envelope.md)：默认 A；zapi 成败统一 |
| L2/L3 端口 | `zf g port store\|cache\|bus`；抄 `examples/ports-l2` / `ports-l3` |
| 新定时 / 缓存 / MQ | Plugin + Manager；跨机用 Outbox→Bus（[outbox.md](outbox.md)·[bus.md](bus.md)）或 `QueueNatsClient` / `QueueRobustMQClient` |
| 新字符串 / 时间工具 | `kit/*`，不依赖 Server |
| 半成品能力 | `experimental` + ADR，测够再升 stable |
| 改框架公开 API | `main.zig` + 测试 + CHANGELOG / `.life` |
| 提交前 | `zf check` + `zig build test`（257p/11s） |

---

## 12. 反模式（架构债来源）

- 手搓整份 `handler` / `service` / `model`，绕过 `zf`
- 在 zone 外改生成文件，再手工 merge
- 同一模块 `actions.zig` 与散落 `app.get/post` 双真源
- Service 里直接操作 `Context` / 写 Cookie
- Handler 里开事务又在 Model 里再开一层，边界不清
- 生产依赖 `experimental` 或未钉 Zig 版本
- `catch {}` / `@panic` 吞掉 I/O 与锁错误
- `kit` 反向依赖 `core`，造成环
- 信任任意 `X-Forwarded-For` 做限流 / 审计
- 为千万级提前拆微服务，却仍把 Session 放单机内存
- Service 直连具体 MQ/驱动，没有 `ports`，导致 L2/L3 无法换适配器
- 错误体改成 zapi、成功体仍用 `{ok}` / `{data}`（半套信封）
- 手搓 `renderJson(.{ .err = … })` 替代 `return error.*` / `failHttp`
- `createX(&.{ … })` 传入拦截器（临时 cfg → UAF）

---

## 13. 渐进式规模（摘要）

| 阶段 | 代码重点 |
|------|----------|
| L0 | `modules/*` 三层 + SQLite（或 zent）；可选 `actions.zig` |
| L1 | `main` 装配 Metrics / 限流 / CSRF / SecurityHeaders / RequestId（`examples/production`） |
| L2 | `ports` + `adapters`；Redis 会话；主从 Store（`zf g port` / `ports-l2`） |
| L3 | `tenant_id` / 幂等；`ports/bus` + workers（`ports-l3`） |

详情：[progressive_architecture.md](progressive_architecture.md)、[scale_to_millions.md](scale_to_millions.md)。  
能力何时可用：[best_practices.md](best_practices.md) §2。

---

## 14. 一句话

ZFinal 的架构最佳实践 = **生成器定义模块骨架，三层固定依赖方向，路由用 actions 真源，框架按 core/db/plugin/kit 分工，稳定 API 与实验隔离，HTTP 信封模块内统一（默认 HttpError），拦截器 cfg 自持有，内存与安全默认偏保守，用测试和 `zf check` 锁边界；规模上按 L0→L3 只换装配与适配器，不推翻模块边界。**
