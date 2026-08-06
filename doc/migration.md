# 升级 / 迁移指南（v0.13 → v0.21）

> 面向从旧版本（特别是 v0.13.x）升级的项目。破坏性变更按版本列出，附
> workaround 迁移建议。完整变更见 [`CHANGELOG.md`](../CHANGELOG.md)。
>
> **≤ v0.13**：CHANGELOG 最早可查 v0.1.0（2024-12）；若从 v0.13 之前升级，
> 先升到 **v0.13.11**（该版本是 0.13 系列稳定点，`doc/zent.md` 等文档对齐），
> 再按本指南逐版本迁移。0.13→0.16 的核心是 **Zig 0.17 迁移**（见 §1 首行）。

## 1. 破坏性变更清单

| 版本 | 变更 | 迁移动作 |
|------|------|----------|
| 0.16+ | **Zig 0.17 迁移**（`io_instance`、`std.Io.Timestamp`、`ArrayList` API、`Thread`） | 见 CHANGELOG 0.16 段的迁移记录；`@cImport` 移除 → `b.addTranslateC` |
| 0.17 | **`Context.getHeader` 安全修复**：body 读取后 `iterateHeaders` assert → 必须走 `cacheHeaders()` 快照；0.21.1 起**大小写不敏感**（RFC 9110） | 旧代码里"body 后读 header"的自定义 workaround 可删除；`getHeader("origin")` 现在能命中小写请求头 |
| 0.20.x | **DB result API**：`Row.cells` 为 `[]Cell`（typed union，was `[]?[]const u8`）；`ResultSet.addRow` 同 | 外部 `getText/getInt/getBool/getCurrentRowMap` **不受影响**（自动适配）；直接访问 `cells` 的代码改用 getter 或按 Cell 分支 |
| 0.20.x | **绑定与信封**：`bindQuery`/`bindJson` 错误时渲染 `{err}` 信封并 `markResponded`；新增 `parseQuery`/`parseJson` 纯解析变体（返回 bool，不渲染） | 自定义 `{code,msg,data}` 契约的项目改用 `parseQuery`/`parseJson`，自己渲染 |
| 0.20.x | **WebSocket API**：`ZFinal.addWebSocket` → 101 + `handler(ws)`；`ws.queryParam(name)` 读取握手 URL query | 弹幕/房间号等传参从"首条 join 消息"迁移到握手 query（`/ws?room_id=42`） |
| 0.21.0 | **`ServerConfig` 新增字段**（`access_log` 等）—— struct 字面量构造不受影响 | 显式 `setConfig(.{...})` 若需保留 `setPort` 值，现在顺序无关（`setPort` 优先） |

## 2. v0.13 时代 workaround 迁移

| 旧 workaround | v0.21 状态 | 建议 |
|---------------|-----------|------|
| **logout no-op**（登出不失效 token） | 0.13 时代被掩盖的缺陷 | 升级后必须验证登出逻辑；`JwtAuthConfig` 支持 `previous_secret` 轮换，登出用 `auth_tokens`/session 失效 |
| **getHeader 防御**（body 后读 header 的 try/catch 包裹） | 0.20.17 起 `cacheHeaders` 快照，不再崩溃 | 删除防御代码，直接 `ctx.getHeader(...)` |
| **index_php raw target**（手写解析 path） | 路由参数 `:id`/`{id}` + `ctx.getPathParam` | 改用路由参数；`wildcardPath` 处理尾通配（含 `..` 拒绝） |

## 3. 测试收集规则（Zig 0.17）

`zig build test` 只收集 **root 模块可达**（显式 `@import`）的 `test` 块 ——
未 import 的文件里的测试会**静默不跑**。

- 新增测试文件后，确保被某条 `@import` 链引用，或在模块根加聚合：
  ```zig
  comptime {
      _ = @import("binding.zig");
      _ = @import("service_test.zig");
  }
  ```
- `zf new` 模板的测试放在 `src/` 可达路径下；跨模块聚合建议放在模块根文件。
- `zig build test-zf`（代码生成器回归）与 `zig build test` 分开收集。

## 4. `zf check --prod` 检测约定

- `--prod` 对 `main.zig` 做 **needle 内容检测**（`createSecurityHeadersInterceptor`、
  `metricsHandlerFor` 等字符串），并跳过 `.git`/`.zig-cache`/`zig-out`/`node_modules`。
- 自定义布局（无约定命名/封装了拦截器）可能误报缺失：用 `PracticeIgnore`
  配置（`zf check` 的 ignore 机制）声明例外；检测的是"main 里出现这些符号"，
  不是运行时路由注册事实。

## 参考

- [`CHANGELOG.md`](../CHANGELOG.md)（逐版本明细）
- [`doc/best_practices.md`](best_practices.md)（健康检查 / 质量门）
- `PRODUCTION_AUDIT.md`（生产契约）
