# ZFinal 最佳实践复盘（v0.25.0 基线）

> **评估日期**：2026-08-27（与 HEAD `fa9d4c5` 同批）  
> **基线**：`src/version.zig` = `0.25.0` · 绿测工具链 `0.17.0-dev.1567+f0354179a`  
> **范围**：框架本体（`src/` + `tools/zf` + 构建/CI/发布/文档/仓库卫生），不含业务示例功能增补  
> **总索**：[best_practices.md](best_practices.md) · [architecture_best_practices.md](architecture_best_practices.md) · [zfinal_improvements.md](zfinal_improvements.md)（上一轮评估与路线）  
> **证据等级**：**✅ 已复核** = 本次实际运行命令或逐行读码确认；**🔎 待复核** = 静态审查发现，方向明确但未逐一复现

---

## 0. 总评

**骨架是好的，问题集中在"一致性"与"契约执行力"。**

已经成立且值得保持的部分：三层生成器契约（`@generated` + `ai-edit-zone`）、双数据层（`DB`/`zent`）分工、
稳定 / experimental API 分级、产品化质量门（`gate` / `gate-quick` / `check` / `release-check`）、
零依赖默认栈（SQLite + 内建 Queue/NATS/MQ 连接器）、以及相当克制的 TODO 密度（全 `src/` 仅 1 处）。
`zig fmt --check` 在 `src/ test/ tools/ examples/ benchmark/ build.zig` 上全绿。✅

**这一轮的主要风险不是"缺功能"，而是三件事：**

1. **工具链钉版三重漂移**：本机默认 `zig` 已编译不过，CI/Docker 钉的版本更早于源码所需 API —— 宣称的合并门很可能一直是红的（P0-1）。
2. **AI-first 契约在 `zf g` 与 JSON manifest 上被自己的实现破坏**：生成物没有 `@generated`/zone、manifest 写的 zone 名有一半不存在（P0-2、P0-4）。
3. **"可验证性"没跟上版本速度**：版本号、测试数、SECURITY、README、RELEASE_CHECKLIST、doc 索引各说各话；质量门只校验 `version.zig ↔ build.zig.zon` 一条（P1-1）。

上一轮 [zfinal_improvements.md](zfinal_improvements.md) 把"历史高危路径压力回归 / 运维默认接线 / DX 错误信息"列为主题，
方向正确且第一批（B1 阶段契约、A1 池压测、E1 停机回归、C1 错误诊断）已随 v0.25.0 落地。
**本文只列它尚未覆盖或新暴露的问题**，并给出与它对齐的落地建议（§7）。

---

## 1. P0 —— 阻塞级（建议下一版必修）

### P0-1 工具链三重漂移：默认工具链编译失败，CI 钉版早于源码所需 API ✅

**事实链（全部实际执行）：**

| 项 | 值 | 证据 |
|----|----|------|
| 本机默认 `zig` | `0.17.0-dev.1970+67f39b551` | `zig version` |
| 默认工具链跑 `zig build test` | **4 处编译错误** | `src/core/server.zig:331` `Io.VTable` 无 `netWrite`；`src/auth/jwt.zig:351` `*const [512]u8` vs `[512]u8` |
| 仓库绿测工具链 | `0.17.0-dev.1567` → **416 passed; 16 skipped; 0 failed** | 用 zigup 的 1567 实跑 |
| CI / release / Dockerfile 钉版 | `0.17.0-dev.1422+e863bf3be` | `.github/workflows/ci.yml:20,36,54,100,132`、`release.yml:18,47`、`docker/Dockerfile:8` |
| 源码需要的下限 | ≥ 1567 | `CHANGELOG.md:24` 明记：0.23.2 起 `builtin.mode != .Debug` → `.debug`；`src/core/context.zig:898`、`src/db/sql_param.zig:78` 已是小写 |
| `ci.yml` 最后修改 | 2026-08-03 | `git log -1 -- .github/workflows/ci.yml` = `8401541` |
| 1567 兼容提交 | 2026-08-10 | `git log -1 4724510` |

**影响**：`build.zig.zon` 的 `minimum_zig_version = "0.17.0"` 对 dev 工具链没有约束力；
"按 CI 同款版本钉死"这条反复写进 README/文档的建议（`README.md:568`）本身指向一个**编译不过的版本**。
对本机开发者（默认 1970）与 AI agent（`AGENTS.md` 要求 `zig build test` 作为基线）都是直接断点，且失败信息指向 std 内部，极难自愈。

**修复建议**
- 新增 `.zig-version`（单源），CI / release / Dockerfile / `install.sh` / 文档全部引用它；`quality_gate.sh` 增加一条
  "`zig version` == `.zig-version`" 的前置检查。
- CI 增加一个 `latest-dev` canary job（`continue-on-error: true`），提前暴露上游 breakage（与 F1 in [zfinal_improvements.md](zfinal_improvements.md) 一致）。
- `README.md:568` 与 `doc/best_practices.md` 的版本说明改为引用 `.zig-version`，禁止硬编码。

### P0-2 `zf g <type>` 绕过 `safeWrite` / merge / `@generated` 契约 ✅

`tools/zf/cmd_scaffold.zig:171` 的 `generateCode` **从不把 `force` 传给** `generateHandler/Model/Middleware/Service/Task`
（仅 `port` 在 `:212` 拿到），并直接 `std.Io.Dir.cwd().writeFile(...)` 截断写（`:301,353,388`）；
生成内容以 `const std = @import("std");` 开头（`:262`），**没有 `// @generated` 头，也没有任何 `ai-edit-zone` 标记**。

**影响**：`zf g handler User` 会静默覆盖用户已编辑的文件，而 `AGENTS.md` 把"只改 ai-edit-zone""不要手写四件套"作为硬规则。
即框架最核心的差异化契约，在 5 条 `zf g` 路径中的 4 条上不成立。`--force` 的帮助文本（`main.zig:87-92`）与实现不符。

**修复建议**：`generateCode` 全部走 `zf_shared.safeWrite`（21 处已在用），模板补 `@generated` + zone 标记，
`force` 一路透传；`zf g --json` 的 `file` 字段改为带 `written`/`status` 的真实结果。

### P0-3 `--dry-run` 有副作用；用法错误 exit 0；`--dry-run --json` 无输出 ✅

- `tools/zf/cmd_crud.zig` 在 `:352-360` 先 `createDirPath(name)` + `chdir`，`:364-370` 再 `bootstrapProject`，
  **之后**才在 `:399` 判断 `explain_mode or dry_run`。空目录里 `zf crud:sql schema.sql --dry-run` 会真的建工程。
- `:399` 的 dry-run 分支在 `:491` 的 `emitJsonManifest` 之前返回 → `--dry-run --json` 给 agent 的是人类可读文本 + 空 stdout。
- `main.zig` 各缺参分支（如 `:76-80,87-92,249-256`）打印 usage 后正常 `return`，**exit code = 0**；只有未知命令 `:70` 退出 1。

**影响**：AI agent 无法判断成功/失败，也无法在 dry-run 下安全预演。

**修复建议**：把 dry-run 判定提前到任何文件系统副作用之前；dry-run + json 仍输出 manifest（加 `"dry_run": true`）；
所有用法错误 `std.process.exit(2)`。

### P0-4 "AI-first manifest" 与真实生成物不一致，且无 schema 可校验 ✅

`emitJsonManifest`（`tools/zf/cmd_crud.zig:497`）硬编码的 zone 名与生成器实际产出的标记对不上：

| manifest 声称（`cmd_crud.zig:545-547`） | 生成器实际产出（`tools/zf/codegen.zig`） |
|------------------------------------------|------------------------------------------|
| `business rules` ✅ | `business rules`（:889） |
| `validation` ❌ 不存在 | `search predicate`（:799） |
| `auth check` ❌ 不存在 | `model hooks`（:1227） |
| `response shaping` ❌ 不存在 | `handler hooks`（:1452） |
| `extra actions` ✅ | `extra actions`（:1508） |

即 5 个里 2 个不存在、2 个真实 zone 未暴露。同时 `$schema` 指向
`https://zfinal.dev/schemas/manifest-1.json`，仓库内**没有任何 schema 文件或校验测试**；
manifest 由 4+ 处手写 JSON 字符串拼接（`cmd_crud.zig`、`cmd_scaffold.zig`、`cmd_port.zig`、`zent_codegen.zig`、`src/aichat/zf_tool.zig`），
`ZfTool.manifestFromSql` 还缺 `markers`/`ui`，与 `doc/aichat.md:310` 声称的"同一契约"不符。✅

**影响**：agent 按 manifest 去改一个不存在的 zone，会静默改错位置或改到区外；这正是"AI-first"最不能出的错。

**修复建议**：抽出唯一 `manifest.zig`（唯一 JSON 写入者 + `appendJsonString`），把 zone 名从 codegen 常量导出而非复制；
提交 `schema/manifest-1.json` 并在 `zig build test-zf` 里对真实生成物做 schema 校验。

### P0-5 标识符未做净化，SQL 关键字 / 非 ASCII 列名生成非法 Zig ✅

`tools/zf/codegen.zig:1088` 用 `"{s}: {s}{s}"` 直接以内插 `col.name` 作为结构体字段名；
全仓不存在 `isValidIdent` / `sanitize` / 关键字表（grep 无命中）。
`type`、`fn`、`const`、`中文` 等列名会生成非法或语义错误的 Zig。
配套的"生成物必须能被 tokenizer 通过"回归测试（`tools/zf/codegen_test.zig:400`）号称覆盖 6 个 schema，
实际是一个多行字符串、且循环只重生成 `tables.items[0]`。

**影响**：真实世界 SQL（保留字列名、国际化表）直接产出不可编译代码，而质量门测不出来。

**修复建议**：加 `sanitizeIdent`（关键字加后缀 / 非法字符下划线化）+ 保留字表；修正测试让每张解析出的表都过 `std.zig.Tokenizer`。

---

## 2. P1 —— 高（一致性与正确性）

### P1-1 版本元数据全面漂移，且无自动校验 ✅

| 文件 | 声称 | 实际 |
|------|------|------|
| `README.md:11,111,119,676` | v0.24.0 | 0.25.0 |
| `README_CN.md:11-13,106,114,456` | v0.9.3 / 145 tests / codegen 6/6 / 6.8-10 | 0.25.0 / 416 passed |
| `doc/index.md:8,92` | v0.20.15（Zig dev.1422） | 0.25.0（Zig dev.1567） |
| `SECURITY.md:7-11` | 0.20.x 为当前支持 | 0.25.0 |
| `RELEASE_CHECKLIST.md:3,6,19` | v0.3.0 / 88 passed / 12 doc pages | 0.25.0 / 416 / 46 |
| `doc/best_practices.md:3,5`、`architecture_best_practices.md:3,189`、`release_and_quality_gates.md:3` | v0.20.x / 416 / `257p/11s` | 已过期 |

`quality_gate.sh:30-40` 只校验 `src/version.zig ↔ build.zig.zon`。
**修复建议**：门里加"README/SECURITY/doc 索引不得出现比当前 semver 更旧的 `vX.Y.Z`""测试数唯一来源（从测试输出提取写回或引用）"。

### P1-2 CHANGELOG 完整性 ✅

`git tag v0.24.0` 存在，但 `CHANGELOG.md` **没有 `[0.24.0]` 段落**：`[0.25.0]` 之下直接跳到 `[0.23.2]`，
0.24.0 的内容被折叠成 0.25.0 里的第二个 `### Added`（`CHANGELOG.md:15-17`）；也**没有 `[Unreleased]`**，
而 `doc/index.md:94` 与 `zfinal_improvements.md:161` 都在引用它。发布门只 `grep '^## \[semver\]'`（`quality_gate.sh:120-124`），所以能过。
**修复建议**：补 `[0.24.0]` 与 `[Unreleased]`；门里加"版本号严格递减、无重复段落"断言。

### P1-3 `test/` 目录被 `.gitignore` 静默排除出版本控制 ✅

`.gitignore:47` 的 `/test*/` 同时匹配了 `test/`；`git ls-files test/` = **0**，
而 `test/{user,comment,post}_test.zig` 在磁盘上存在、`CONTRIBUTING.md:78` 还把 `test/` 写成集成测试入口。
**修复建议**：把 `/test*/` 收窄为 `/test_crud*/ /testapp*/ /test_sqlite* /test_transient*/`，然后 `git add test/`。

### P1-4 运行时正确性（已复核）

| 问题 | 位置 | 说明 |
|------|------|------|
| 事务提交失败后连接带着未关闭事务回池 | `src/db/db.zig:249-270`、`transactionResult:274-298` | `try self.commit()` 失败直接向上抛，没有 `errdefer rollback`；`ConnectionPool.transaction` 的 `defer release(conn)` 会把脏连接还池 |
| `TokenManager.exists` 无锁读 HashMap | `src/token/token.zig:94-99` | `put`/`validate` 持锁，`exists` 不持锁；注释说"不会造成安全问题"，但并发 rehash 下的读是 UB（该路径在 CSRF 校验上） |
| 空 `trusted_proxies` 时信任 XFF | `src/ext/ext_util.zig:89-106` | `trusted_proxies.len == 0 → peer_trusted = true`，并取 XFF **最左**值；只要打开 `trust_proxy_headers` 就能被伪造 IP 绕过限流/审计 |
| body 只能读一次的契约只在 `getBodyText` 上强制 | `src/core/context.zig:898`（唯一哨兵）、`getFiles:992-1017` | `getFiles` 直接 `readerExpectNone` 再读 body，不查也不置 `body_consumed` |
| 静态路由 key 溢出后丢方法前缀 | `src/core/router.zig:381-383,401-410` | 路径 > ~250B 时 `bufPrint` 失败回退为纯 path，`GET:`/`POST:` 与 `ANY` 三类 key 退化成同一个，方法可能串 |

**修复建议**：`transaction` 在 `commit` 前 `errdefer self.rollback()`；`exists` 加锁（或改 `std.atomic`/快照）；
`trusted_proxies` 为空时取 XFF **最右**段或直接拒绝该头；`getFiles` 复用 `getBodyText` 的守卫；
`staticRouteKey` 改为分配式 key 或对超长路径直接走线性匹配。

### P1-5 合并语义是破坏性的，且 marker 匹配靠子串 ✅

`tools/zf/zone_merge.zig:126-136` 用 `std.mem.indexOf` 找 `ai-edit-zone:` / `end ai-edit-zone`，**不要求它们在注释行**；
`zone_merge.zig:45-73` 的合并结果是"全新生成文件 + 换入 zone 体"，**zone 外的用户改动被静默丢弃**，只打印 `✅ Merged`；
merge / `--force` 都没有备份，写盘是原地截断而非 temp+rename。`safeWrite` 有 21 个调用点但**零测试**。
**修复建议**：marker 匹配锚定到行首注释；merge 前生成 `.bak` 或统一 `.gen.new` 策略并在有 zone 外差异时显式报错；
写盘改 `writeFileAtomic`；给 `safeWrite`/`zone_merge` 补单测（含"用户在区外改了一行"的用例）。

### P1-6 部分质量门实际是 no-op 🔎→✅（关键点已复核）

- `zf check` 的第 2–4 项仍围绕 `.gen.zig` + `ext/` 布局（`cmd_check.zig:78-96,558-632`），
  而当前 `crud:sql` 产出的是一体化 `model/service/handler/actions/routes.zig`（`codegen.zig:711-712` 注明已移除 gen/ext）。
  即新工程上这些检查既不 PASS 也不 WARN——合规门近乎空转。✅（读码确认）
- `safeWrite` 无测试、manifest 无校验测试（见 P0-4）。✅
- `openDir(...) catch return` / `walk(...) catch return`（`cmd_check.zig:563,566`）在任何 IO 错误上静默跳过。🔎

**修复建议**：`zf check` 改成"每个 `src/modules/*/*.zig` 必须有 `@generated` 且至少 1 个 zone；zone 外 diff 即 FAIL"，
并把静默 `catch return` 改为显式 warn。

---

## 3. P2 —— 中（工程纵深）

### P2-1 CI / 验证深度
- 无覆盖率采集、无 fuzz、无 sanitizer / ReleaseSafe-only 之外的 matrix；`gate` 只在 Ubuntu 跑 full，macOS 只跑子集。✅
- `test-int`（`build.zig:185`）与注释掉的 `test-nats`（`build.zig:479`）**从未在任何门/CI 中运行**。✅
- 无 Windows job，但 `doc/index.md:75` 声称跨平台含 Windows。✅
- `quality_gate.sh:44` 的 fmt 范围是 `src/ tools/ examples/ benchmark/ build.zig`，**漏 `test/`**，与 `CLAUDE.md` 写的不一致。✅
- 建议：`zig build test -Doptimize=ReleaseSafe` 进 full gate；加 coverage（kcov/llvm-cov 或自研计数）+ 至少对 `zone_merge`/`multipart`/router 加 fuzz target；把 `test-int` 接进 `test-zf` 或删掉。

### P2-2 发布与供应链
- `release.yml` 只上传 CI artifact：**没有 GitHub Release、没有 release notes、没有 SHA256SUMS、没有签名**。✅
- Actions 全部钉可变 tag（`actions/checkout@v4`、`mlugg/setup-zig@v2`、`upload-artifact@v4`），非 commit SHA；无 `permissions:`、无 `concurrency:`、无 Dependabot、无 CODEOWNERS。✅
- 建议：least-privilege `permissions: contents: read` + release job 单独 `contents: write`；Actions 钉 SHA（Dependabot 维护）；发布时生成 checksums + 引用 CHANGELOG 段落。

### P2-3 文档信息架构与 Agent 指令漂移
- `doc/` 46 个**平铺**文件，至少 21 个未被 `doc/index.md` 链接；另有独立的 `docs/` 顶层目录（`docs/zent-upstream-issues.md`、`docs/superpowers/plans/…`）与 `doc/` 并列。🔎
- `doc/index.md:74` 说 369 tests，`:19` 说 416 tests，自相矛盾。✅
- 同一事实（测试基线）散落在 `AGENTS.md:87`、`CLAUDE.md:51`、`doc/index.md:19`、`best_practices.md:5`、`architecture_best_practices.md:189`、`README_CN.md` 六处，必然漂移。✅
- `.claude/skills/` 里 `zfinal-evolution.md` 与 `zfinal-evolve.md` 高度重叠；`CLAUDE.md` 的路由表未收录 `zfinal-debug` / `zfinal-evolve`。🔎
- 建议：`doc/` 分 `guides/ reference/ adr/ reviews/` 子目录；测试数改为单一来源（`benchmark/BASELINE.md` 或生成）；agent 规则去重为"AGENTS.md 为唯一真源，CLAUDE.md 只做路由"。

### P2-4 AI runtime 与模板（🔎，方向明确待复核）
- `src/plugin/http_client.zig:12` 的 `timeout_ms = 10_000` **全文件仅此一处**（死配置），`requestWith/requestStream` 不传超时 → 上游挂起会永久阻塞；AI tool 预算是"跑完再比时间"（`skill.zig:264-268`）；MCP 只在两次阻塞读之间查 deadline。✅（timeout 死配置已复核）
- `provider.chatStream` 传输失败时回退 `chatWithUnlocked` 并重发**完整**内容到 `on_delta`，已收到的增量会重复。🔎
- `src/template/template.zig` 无任何 HTML 转义/`|safe` 过滤器（grep `escape` 无命中）；`src/template/htmx.zig:28` 的 `renderTemplate` 是丢弃全部参数的 TODO stub。✅（无转义已复核）
- MCP 子进程 `.stderr = .ignore` 且继承完整 env（API key 泄漏面 + 无诊断）。🔎
- 建议：把 deadline 贯穿到 `fetch`/read 并在超时取消子任务；`chatStream` 仅在"零 delta"时才回退；模板默认转义 + 显式 `|safe`，stub 改 `@compileError`。

### P2-5 仓库卫生
- 顶层游离文件：`test_gen_crud.zig`（仅被从不运行的 `test-int` 引用）、`test_nats.zig`、`test_pg_crud.zig`（0 引用）被跟踪。✅
- `src/auth/testdata_rs256_priv.pem` 被跟踪（测试用、代码实际内嵌 `.der`，但会触发密钥扫描告警）。✅
- `public/**/admin*.html`（9 个生成态 HTML）与 `.life/`（agent 记忆 + ADR）进版本库；ADR 值得留，`public/` 生成物建议忽略。🔎
- `.github/ISSUE_TEMPLATE/bug_report.md:34-35` 占位仍是 Zig 0.14.0 / ZFinal 1.0.0。🔎

---

## 4. 建议落地顺序

| 批次 | 项 | 理由 |
|------|----|------|
| **第一批（下一个 patch）** | P0-1 工具链单源 + CI 修钉 | 不修则"绿"的定义本身是错的，其余验证都失去意义 |
| **第一批（同一批）** | P0-2 `zf g` 走 safeWrite+zone；P0-3 dry-run 无副作用 + 非零退出码 | 改动小、直接消除"生成器毁用户代码"和数据丢失风险 |
| **第二批（v0.26）** | P0-4 manifest 单源 + schema；P0-5 标识符净化 + 修回归测试 | AI-first 契约的可信度主线 |
| **第二批** | P1-1/P1-2 版本与 CHANGELOG 门；P1-3 `test/` 入库 | 一致性自动化，一次投入长期收益 |
| **第三批** | P1-4 运行时五则 + P1-5 merge 原子化/备份 + P1-6 `zf check` 重写 | 需要更细的并发/失败路径测试 |
| **长线** | P2-1 CI 纵深、P2-2 发布工程、P2-3 文档 IA、P2-4 AI runtime | 生态与运维 |

与上一轮路线的关系：原 A2/A3/A4/B2/B3/C2/C3/D3/E2–E4 仍然有效，本文 P0/P1 应插到它们**之前**。

---

## 5. 附录：本次评估实际执行的命令与结果

```bash
zig version                                   # 0.17.0-dev.1970+67f39b551
zig build test                                # ✗ 4 compile errors (server.zig:331, jwt.zig:351)
~/.local/share/zigup/0.17.0-dev.1567+f0354179a/files/zig build test
                                              # ✓ 416 passed; 16 skipped; 0 failed
zig fmt --check src/ test/ benchmark/ tools/ examples/ build.zig   # ✓ 通过
git ls-files test/ | wc -l                    # 0（目录被 .gitignore:47 /test*/ 排除）
git rev-parse -q --verify refs/tags/v0.24.0   # 存在；CHANGELOG 无 [0.24.0]
grep -n "^## \[" CHANGELOG.md | head          # 0.25.0 → 0.23.2，无 [Unreleased]
grep -o "ai-edit-zone: [a-z ]*" tools/zf/codegen.zig | sort -u
                                              # search predicate / business rules /
                                              # model hooks / handler hooks / extra actions
```

> 说明：**评估阶段为只读**（除本文档与 `doc/index.md` 的一行索引外未改动文件）；后续修复见 §6。

---

## 6. 修复进展（同批已落地）

> 评估后立即实施的修复。验证在 Zig `0.17.0-dev.1567+f0354179a`（`.zig-version`）下执行。

### 已修复并验证

| 条目 | 修复内容 | 验证 |
|------|----------|------|
| P0-1 工具链漂移 | 新增 `.zig-version` 单源；CI / release / Dockerfile 读取它；gate 校验 `zig version`（release 模式硬失败）；补 `master` canary + Actions Dependabot | `quality_gate.sh quick` 工具链检查 PASS |
| P0-2 `zf g` 契约 | 五类生成全部走 `safeWrite` + `@generated` 头 + `ai-edit-zone`，`--force` 透传；manifest 增 `written` / `ai_edit_zones` / `error` | e2e：再生成保留 zone 内编辑；`--force` 覆盖并留 `.bak` |
| P0-3 dry-run / 退出码 | dry-run 判定前移到任何文件系统副作用之前；`--dry-run --json` 输出 manifest；用法错误 exit 1 | e2e：空目录 dry-run 不产生 `build.zig.zon`；`zf g handler` 退出 1 |
| P0-4 manifest 漂移 | zone 名统一取自 `codegen.crud_edit_zones`；提交 `schemas/manifest-1.json` + `zent-manifest-1.json`；新增一致性测试 | `test-zf` 49/49 |
| P0-5 标识符净化 | 保留字 / 非 ASCII 列名改用 `@"..."`；DB 列名保持不变；回归测试遍历所有表 | `test-zf` + `@"中文"` 通过 tokenizer |
| P1-1 / P1-2 版本与 CHANGELOG | 全部对齐 v0.25.0；补 `[Unreleased]` 与 `[0.24.0]`；测试基线更新为 **418** | grep 无残留旧版本号 |
| P1-3 `test/` 入库 | `.gitignore` 收窄 `/test*/` → `/test_*/`，`test/` 重新跟踪 | `git ls-files test/` = 3 |
| P1-4 运行时五则 | `transaction` 提交失败回滚；`token.exists` 加锁；XFF 取最右；`getFiles` body 守卫；路由 key 溢出不再丢方法前缀 | `zig build test` → 418 passed / 16 skipped / 0 failed |
| P1-5 写入安全 | `safeWrite` 改为 `<path>.tmp` + rename 原子写，覆盖/合并前留 `.bak`；`.gen.new` / `.bak` 入 gitignore | e2e：`--force` 生成 `.bak`，无 `.tmp` 残留 |
| P1-6 `zf check` | 新增当前单文件布局的 zone 契约检查（`@generated` 但无 zone 且无 `DO NOT EDIT` 即告警） | 新工程 `zf check` → 6 pass / 0 warn / 0 fail |

### 尚未处理（建议下一批）

- **P2-1** 覆盖率采集 / fuzz / sanitizer、Windows job、`test-int` 复活与 CI matrix。
- **P2-2** GitHub Release 发布物 + SHA256SUMS + 签名；Actions 由 tag 改钉 commit SHA。
- **P2-3** `doc/` 目录分层与 21 个未链接文档；`AGENTS.md` / `CLAUDE.md` / `.claude/skills/` 规则去重。
- **P2-4** AI runtime 超时贯穿到 `fetch`/read；`chatStream` 回退去重；模板默认 HTML 转义；MCP 子进程 stderr/env。
- `zf check` 中 `.gen.zig` + `ext/` 的旧检查仍保留（兼容存量工程），可在下个大版本移除。
- `zent_codegen` 的字段名走其自身校验，未复用 `crud:sql` 的 `zigFieldName`（两条生成路径的净化策略仍不一致）。

