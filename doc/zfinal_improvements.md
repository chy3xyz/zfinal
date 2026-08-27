# ZFinal 可改善方向评估（框架级）

> **版本基线**：v0.24.0 / Zig `0.17.0-dev.1567` · 评估日期 2026-08-27  
> **范围**：框架本体（`src/` + `tools/zf` + 示例/文档/CI），不含具体业务示例的功能增补  
> **总索**：[best_practices.md](best_practices.md) · [architecture_best_practices.md](architecture_best_practices.md) · [PRODUCTION_AUDIT.md](../PRODUCTION_AUDIT.md)

## 0. 总评

框架骨架已经成立：三层生成器契约（ai-edit-zone）、双数据层（SQL / zent）、
稳定-实验 API 分级、质量门（gate/gate-quick/check/release-check）、
369+ 测试基线、live driver CI。**当前的主要改善空间不在"缺大块功能"，而在**：

1. 历史高危路径（池 / 并发 / 内存所有权）需要**压力验证闭环**而非只靠点修复；
2. 运维自动化（reaper、停机、迁移联动）默认不接线，靠用户抄示例；
3. DX 细节（错误信息、comptime 提示）仍是"编译器报错"级别；
4. 生态分发（marketplace）缺信任链。

以下按优先级分组。P0 = 下一两个版本内值得做；P1 = v0.25 路线；P2 = 长线。

---

## A. 数据层与运行时可靠性

### A1（P0）连接池压力回归进 CI
历史上 segfault/UAF 集中爆发在 `ConnectionPool`（struct copy → mutex 损坏 →
`pthread_mutex_lock` 返回值丢弃 → 0xaa 填充读）。v0.12.7–v0.13.0 已逐层修复
（堆分配、magic、checked_out、ping-outside-lock、double-release 检测），但
验证手段仍是"点修复 + 单测"。建议：

- 在 `docker/test-compose.yml` 增加 **burst soak** job：N 线程 × M 次
  acquire/release/事务循环，跑 ReleaseSafe + GPA（测试分配器已能暴露
  0xaa 模式），作为 nightly CI。
- 把"同连接复用 ≥12 次"这类历史必现场景固化为 `src/db/integration_test.zig`
  的命名用例，防回归。

### A2（P1）Reaper 默认接线
`ConnectionPool.startReaper(interval)` 已存在（pool.zig:100），但
`reaper_interval_ms = 0` 默认关闭，且示例里未示范。两个改法：

- `examples/production` / `zf new` 模板中显式 `startReaper(30_000)`；
- 文档 `database.md` 明确语义：不配 reaper 时，只有 acquire 路径的
  ping 会清死连接——idle 过期连接会一直占着 `max_connections` 名额。

### A3（P1）PG 二进制 wire format 实测
此前已识别：`run-db-bench` 基础设施就绪，但 `resultFormat=1 vs =0` 的
server CPU / wire bytes 实测一直未跑。补一次量化报告（进 `benchmark/BASELINE.md`），
决定 ORM 是否默认切二进制。

### A4（P1）`Row.intAt` 接入 ORM 热路径
`db/model.zig` 的字段解码默认路径若仍走文本 parse，把已实现的
`Row.intAt`（二进制直读）设为 PG/MySQL 二进制模式下的默认解码，
白拿 ~1.04–2x。前提：A3 的实测确认收益。

### A5（P2）zent 上游遗留
`docs/zent-upstream-issues.md` #3–#6 仍 open（QueryEdge 结果顺序未保证、
builder 命名不一致 `Save/Exec`、data_scope 空上下文语义未文档化、
shard/CrudService/sensitive 缺示例）。其中 #3 影响 zfinal feed 的
O(n·m) 映射——值得继续推上游修。

---

## B. HTTP / API 人体工学

### B1（P0）Context 生命周期阶段契约
v0.20.17 修的 `getHeader`-after-body 崩溃是症状：**"读 body 后哪些 API 仍可用"**
没有系统性保证。建议：

- `core/context.zig` 顶部写阶段契约注释（dispatch → headers 快照 → body → render），
  列出每个阶段的合法 API；
- Debug 模式下对越阶段调用加 `std.debug.assert`，把运行时崩溃变成明确的断言信息。

### B2（P1）`bindJson` 字段默认值要求 → 友好编译错
DTO 字段缺默认值时 `.{}` 编译失败，报错落在泛型深处。可在 `bindJson` 里加
comptime 检查：`@compileError("bindJson DTO field '" ++ name ++ "' needs a default value (missing param keeps default)")`。

### B3（P1）信封混用检测收紧
`zf check --practice` 已有信封启发式。补一条：**同一模块内成功体与错误体
风格不一致**（半套 zapi）直接 WARN/FAIL，对应 architecture 文档 §12 反模式。

### B4（P2）从 actions.zig 反推 client SDK
`zf openapi` 已能从 actions 生成 spec。下一步是 TS/Dart client 生成，
把"路由真源"价值延伸到前端。

---

## C. CLI / DX

### C1（P0）生成器错误信息
`zf crud:sql/zent` 参数或 schema 不匹配时报错浅（常只有一行）。每个失败点
应输出：输入位置（文件:行 / 参数名）+ 期望形态 + 一个合法示例。
这是 AI agent 自纠正能力的关键——manifest 消费方靠错误信息重试。

### C2（P1）`schema.gen.sql` ↔ `zf migrate` 联动
`zf migrate` 已有完整 runner（new/run/down/status，tools/zf/cmd_migrate.zig）。
断点在于：`zf crud` 生成的 `schema.gen.sql`（含注解派生索引）与
`migrations/` 目录互不知晓。可做 `zf migrate diff`：对比 model 注解与已应用
迁移，生成增量 DDL 草稿。对应此前"注解自动补索引"的下一步。

### C3（P2）marketplace 信任链
`--registry` 已支持自定义源。缺：条目 SHA256 校验和、catalog 签名、
版本约束（`zfinal >= 0.24`）。没有信任链前，`zf market install` 不宜进生产流程。

---

## D. 测试 / CI

### D1（P0）故障注入测试
现有测试是功能性的。对历史高危面补 chaos 用例：

- 连接中途被 server 端断开 → acquire 必须重建而非 crash；
- `release` 后进程内继续使用（UAF）→ magic/check_out 必须拦截；
- 请求中途 client RST → handler 资源必须释放（GPA 验证）。

### D2（P1）示例一致性扫描
zfsaas 曾出现 `backend/schema.sql` 与 `backend/src/schema.sql` 双份 DDL。
加一个 gate 检查：示例目录内同名 schema 文件内容一致（或改成符号链接/单源生成）。

### D3（P2）测试金字塔补齐
service 级测试充足；缺端到端二进制级 smoke（`zig build run-*` + curl 断言）
的统一 harness。`scripts/smoke-zent-shop.sh` 是孤例，可泛化为
`zig build smoke` 覆盖所有可运行示例。

---

## E. 生产就绪 / 运维

### E1（P0）优雅停机回归确认
历史上 `shutdown.registerHandlers` 因子线程 awaiter panic 被业务方注释掉。
需在框架测试里固化：有 in-flight 请求时 SIGTERM → drain → 退出码 0。
若已修，把 `registerHandlers` 在 `examples/production` 默认打开作为证明。

### E2（P1）零停机部署文档
`reverse_proxy.md` 有 keep-alive 契约，但缺"滚动重启时反代如何摘流量"
（健康检查失败阈值 + drain 窗口）的 runbook 段落。

### E3（P2）OpenTelemetry 出口
现有 Logger/Metrics/access-log 是自有格式。加一个 opt-in OTLP exporter
（plugin/metrics_exporter 旁边），不引入重依赖，仅 HTTP push。

### E4（P2）静态 musl 单二进制
zfsaas 的 Dockerfile 已验证 debian-slim 路径。补官方 `-Dtarget=x86_64-linux-musl`
静态构建说明，服务低配 VPS 场景（用户已提过的诉求）。

---

## F. 兼容策略

### F1（P1）Zig 版本钉住策略显式化
`build.zig.zon` 声明 `minimum_zig_version = 0.17.0`，但实际 pin 在
`0.17.0-dev.1567` 且多次随 dev 版迁移（dev.1422 → 1567）。建议：

- 文档明确"跟 dev 还是等 0.17 release"的策略与升级触发条件；
- CI 加一个 latest-dev 的 canary job（允许失败），提前暴露上游 breakage。

---

## 建议落地顺序

| 批次 | 项 | 理由 |
|------|-----|------|
| ~~第一批（v0.24.x）~~ **✅ 已完成（2026-08-27，见 CHANGELOG Unreleased）** | A1 压力回归（4 个池压测 + SQLite 并发驱动修复）、E1 停机回归（测试固化 drain 路径）、C1 错误信息（DDL 失败诊断 + DSL 示例 hints）、B1 阶段契约（文档 + Debug 断言） | 全是历史事故面的"防再发"，改动小收益直接 |
| 第二批（v0.25） | A2 reaper 默认、A3/A4 二进制实测+接入、B2/B3、C2 migrate diff | 性能与 DX，需一轮实测支撑 |
| 第三批（长线） | D3、E2–E4、C3 信任链、A5 zent 上游 | 生态与运维纵深 |

## 一句话

ZFinal 的功能面已经超前于它的**验证与默认配置**——下一阶段的改善主题应是：
把历史上靠点修复摁下去的高危路径变成 CI 里的压力回归，把运维能力从
"示例里抄"变成"默认接线"，把 DX 错误从编译器深处提到用户面前。
