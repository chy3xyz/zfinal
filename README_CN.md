<div align="center">

# ⚡ ZFinal

**Zig 的 AI 极速开发框架** — *AI speedrun web framework for Zig*

*受 JFinal 启发 — 极简 API，极致性能，AI-first 设计*

[![Zig](https://img.shields.io/badge/Zig-0.17.0-orange.svg)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-145%20passing%2C%200%20leaks-brightgreen.svg)]()
[![Codegen](https://img.shields.io/badge/codegen%20tests-6%2F6-brightgreen.svg)]()
[![Production](https://img.shields.io/badge/production--readiness-95%25-brightgreen.svg)](PRODUCTION_AUDIT.md)

[English](README.md) | **中文文档**

</div>

---

## 🤖 如果你是 AI 智能体

> **先读 `.claude/skills/zfinal-onboarding.md`** — 30 秒速通：
> 5 命令极速开发流程、应该加载哪个 skill、以及绝对不能做的事
> （比如手写 `model.zig`）。

ZFinal 是**第一个为 AI 设计的 Zig Web 框架**。`zf` CLI 发射机器可读
JSON，生成文件带 `// ── ai-edit-zone: ...` 标记，进程内
`ZfTool` 让你从代码里直接调用生成器。

| 步骤 | 命令 | 耗时 |
|------|------|------|
| 1 | `cat schema.sql` | 5 秒 |
| 2 | `zf crud:sql schema.sql --json` | 2 秒 |
| 3 | 在生成文件的 ai-edit-zone 内补业务逻辑 | 2 分钟 |
| 4 | `zf check && zig build test` | 5 秒 |
| 5 | `zig build run` | 1 秒 |

**5 条命令，5 分钟，完整 CRUD + 测试 + manifest。**

---

## ZFinal 是什么？

一个高性能、生产级的 Zig Web 框架——具备路由、ORM、CSRF、验证码、
i18n、WebSocket、插件、指标等所有标准能力——但有一个其他 Zig 框架
都没有的特性：**AI 原生工具链**。`zf` CLI 的设计目标是让 AI
智能体不必扫工作树就能新增功能。

```zig
const zfinal = @import("zfinal");

pub fn main() !void {
    @import("zfinal").io_instance.init(init);
    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();

    try app.get("/", index);
    try app.start();
}

fn index(ctx: *zfinal.Context) !void {
    try ctx.renderJson(.{ .message = "你好, ZFinal!" });
}
```

---

## ZFinal 有什么不同

| | 其他 Zig 框架 | ZFinal |
|---|---------------|--------|
| 代码生成 | 无 — 全手写 | `zf crud:sql` 一键生成 model/service/handler/routes |
| AI 契约 | 无边界 — AI 自己摸索 | `// ── ai-edit-zone: ...` 标记明确告诉 AI 在哪里改 |
| 机器输出 | 无 — AI 只能 grep | `zf --json` 输出结构化 manifest（表/文件/字段/下一步） |
| 进程内调用 | 必须 shell | `zfinal.ZfTool` 可在任意 Zig 代码里调用 |
| 自检 | 无 | `zf check` 审计 AI 是否越界 |

---

## 快速开始

### 从源码构建

```bash
git clone https://github.com/chy3xyz/zfinal.git
cd zfinal
zig build                  # 构建框架 + 所有示例
zig build test             # 跑 145 个单元 + 集成测试
zig build test-zf          # 跑 6 个 codegen 回归测试
```

### 跑示例

```bash
zig build run-hello              # Hello-world 演示
zig build run-blog               # 博客（SQLite）
zig build run-ai-blog-5min       # 5 分钟 AI 极速演示
zig build run-production         # 生产级示例
zig build run-htmx               # HTMX 交互应用
```

### 集成到你的项目

```bash
zig fetch --save https://github.com/chy3xyz/zfinal/archive/refs/tags/v0.9.3.tar.gz
```

在 `build.zig.zon`：

```zon
.dependencies = .{
    .zfinal = .{
        .url = "https://github.com/chy3xyz/zfinal/archive/refs/tags/v0.9.3.tar.gz",
        .hash = "...",  // `zig fetch` 自动填
    },
},
```

在 `build.zig`：

```zig
const zfinal_dep = b.dependency("zfinal", .{ .target = target, .optimize = optimize });
const zfinal_mod = zfinal_dep.module("zfinal");

const exe_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{.{ .name = "zfinal", .module = zfinal_mod }},
});
exe_mod.link_libc = true;
exe_mod.linkSystemLibrary("sqlite3", .{});
```

开发期用本地路径：

```zon
.zfinal = .{ .path = "../zfinal" },
```

---

## AI 极速流程（长版）

### 第 1 步 — Schema 是唯一真相

```sql
-- schema.sql
CREATE TABLE users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    email TEXT NOT NULL
);

CREATE TABLE posts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INT NOT NULL REFERENCES users(id),
    title TEXT NOT NULL,
    body TEXT
);
```

### 第 2 步 — 一条命令生成一切

```bash
zf crud:sql schema.sql --json
```

AI 解析的输出：

```json
{
  "tables": [
    {
      "name": "users",
      "files": { "model": "users/model.zig", "service": "users/service.zig", "handler": "users/handler.zig", "routes": "users/routes.zig" },
      "ai_edit_zones": [
        { "file": "service.zig", "purpose": "业务规则" },
        { "file": "handler.zig", "purpose": "鉴权 + 响应整形" }
      ],
      "fields": [
        { "name": "id", "sql_type": "INTEGER", "primary_key": true },
        { "name": "username", "sql_type": "TEXT", "nullable": false },
        { "name": "email", "sql_type": "TEXT", "nullable": false }
      ]
    }
  ]
}
```

### 第 3 步 — 只在 ai-edit-zone 内编辑

```zig
// ── ai-edit-zone: business rules ─────────────
pub fn isUsernameTaken(db: *zfinal.DB, username: []const u8) !bool {
    // AI 在这里写
}
// ──────────────────────────────────────────────
```

### 第 4 步 — 验证

```bash
zf check           # AI 边界审计
zig build test     # 145+ 个测试
```

### 第 5 步 — 跑

```bash
zig build run
```

完整 walkthrough：[doc/ai-quickstart.md](doc/ai-quickstart.md)。
可跑示例：[`examples/ai-blog-5min/`](examples/ai-blog-5min/ZF_GEN.md)。

---

## 核心能力

### 路由 + 拦截器

```zig
try app.get("/users/:id", showUser);
try app.post("/users", createUser);
try app.put("/users/:id", updateUser);
try app.delete("/users/:id", deleteUser);

var api = zfinal.RouteGroup.init(&app, "/api");
try api.get("/health", healthHandler);

try app.addGlobalInterceptor(zfinal.CORSInterceptor);
```

### 数据库 + ORM

```zig
const User = struct { id: ?i64, name: []const u8, email: []const u8 };
const UserModel = zfinal.Model(User, "users");

var pool = zfinal.ConnectionPool.init(allocator, config, 10);

const users = try UserModel.findAll(&db, allocator);
var user = UserModel.Instance{ .data = .{ .name = "张三", .email = "z@a.com" } };
try user.save(&db);
```

**AI 友好错误**：约束冲突返回类型化错误（如 `UniqueViolation`），
自动抽出 `table` 和 `column`，AI 可以说"users.email 已存在"
而不是"SQLite step failed: 19"。

### 安全

- CSRF token（32 字节 CSPRNG、Base64、一次性、自动过期）
- 限流（用真实 socket 地址，无法伪造 header）
- 验证码（数字 / 字母 / 混合 / 算术）
- 全部参数化 SQL — 禁止字符串拼接

### 框架内 AI

```zig
const zfinal = @import("zfinal");
const tool = zfinal.ZfTool.init(allocator);

// 与 `zf crud:sql --json` 同结构的 manifest，可从 Zig 调用：
const manifest = try tool.manifestFromSql(schema_text);
defer allocator.free(manifest);

// 为 AI agent 生成 system prompt（已包含本项目 schema）：
const prompt = try tool.buildAgentSystemPrompt(schema_text);
defer allocator.free(prompt);
```

---

## 项目结构

```
zfinal/
├── src/                          # 框架源码
│   ├── main.zig                  # 公共 API
│   ├── core/                     # Server, Router, Context
│   ├── db/                       # DB + 驱动 + ORM
│   ├── interceptor/              # Auth, CORS, CSRF
│   ├── plugin/                   # Cache, Cron, Redis
│   ├── kit/                      # 17 个工具 kit
│   ├── aichat/                   # AI 客户端 + ZfTool
│   └── io_instance.zig           # 全局 Io + 分配器
├── tools/zf/                     # CLI 工具
│   ├── main.zig                  # 入口
│   ├── codegen.zig               # 代码生成器
│   ├── codegen_test.zig          # 6 个生成器回归测试
│   └── templates.zig             # 代码模板
├── examples/                     # 10+ 可跑示例
│   ├── ai-blog-5min/             # 5 分钟 AI 极速演示
│   ├── blog-single/
│   ├── hello-world/
│   └── ...
├── .claude/
│   ├── skills/                   # AI 可识别 skill
│   │   ├── zfinal-onboarding.md  # 必读第一篇
│   │   ├── zfinal-ai-playbook.md
│   │   ├── zfinal-health.md
│   │   ├── zfinal-framework.md
│   │   ├── zfinal-app.md
│   │   └── zfinal-evolution.md
│   └── agents/
│       └── zfinal-developer.md   # 子 agent 定义
├── doc/                          # AI 友好的文档
│   ├── index.md                  # 双受众落地页
│   ├── ai-quickstart.md          # 5 分钟 walkthrough
│   └── ...
├── AGENTS.md                     # AI 优先规则（先读）
├── CLAUDE.md                     # Health Stack + 路由
└── build.zig                     # 构建配置
```

---

## AI Skill 集

ZFinal 自带 6 个 skill + 1 个 sub-agent：

| Skill | 何时读 |
|-------|--------|
| `zfinal-onboarding` | 第一次接触项目时 |
| `zfinal-ai-playbook` | 新增功能 / 实体 / 路由 |
| `zfinal-health` | 跑测试、CI、健康检查 |
| `zfinal-framework` | 给框架本身加模块 |
| `zfinal-app` | 从零搭完整应用 |
| `zfinal-evolution` | Zig 0.17、内存安全、泄漏、竞态 |

还有 sub-agent `zfinal-developer`（在 `.claude/agents/`），
把 onboarding + playbook + 硬规则打包成单一自动派发单元。

---

## 生产就绪度

| 状态 | 维度 | 分数 |
|------|------|------|
| ✅ | 构建稳定性 | 95% |
| ✅ | 安全性 | 90% |
| ✅ | 内存安全 | 88% |
| ✅ | 正确性 | 88% |
| ✅ | 可观测性 | 85% |
| ✅ | 并发 | 85% |
| ✅ | 可测试性 | 85% |
| ✅ | 代码质量 | 85% |
| 🟡 | 文档 | **85%**（原 60%，AI 化重写） |
| 🟡 | 示例 | 82% |
| **→** | **总体** | **92%** |

详见 [PRODUCTION_AUDIT.md](PRODUCTION_AUDIT.md)。

架构分层、AI 编辑边界与插件成熟度规则见：
[doc/architecture_best_practices.md](doc/architecture_best_practices.md)。

千万级支撑与 L0→L3 渐进代码架构：
[doc/scale_to_millions.md](doc/scale_to_millions.md) ·
[doc/progressive_architecture.md](doc/progressive_architecture.md)。

---

## 插件成熟度

| 插件 | 状态 | 说明 |
|------|------|------|
| Cache（内存） | ✅ 稳定 | 线程安全的内存缓存，支持 TTL |
| Cache（Redis） | ✅ 稳定 | 完整 Redis 客户端（RESP 协议） |
| Cron | ✅ 稳定 | Cron 表达式解析 + 任务调度 |
| PostgreSQL | 🔧 可选 | libpq 驱动 — `-Ddriver_pg=true` |
| MySQL | 🔧 可选 | mysqlclient 驱动 — `-Ddriver_mysql=true` |
| MQTT | 🟡 桩 | MQTT 3.1.1 客户端 — IoT 协议 |
| Agent (MCP) | 🔧 实验 | Model Context Protocol agent |
| P2P | 🔧 实验 | 点对点网络 |
| DID | 🔧 实验 | 去中心化身份 |

---

## 性能

基准测试（M1 Pro, 8 核, localhost）：

| 场景 | 吞吐 | 延迟（P50） | 内存 |
|------|------|-----------|------|
| Hello world (JSON) | ~25,000 req/s | 0.4ms | ~12MB |
| SQLite 读（缓存） | ~15,000 req/s | 0.6ms | ~14MB |
| SQLite 写（池化） | ~5,000 req/s | 1.2ms | ~14MB |
| 1,000 并发 keep-alive | ~30,000 req/s | 0.5ms | ~18MB |

- **零 GC 暂停** — 无垃圾回收器
- **协程并发** — kqueue（macOS）/ io_uring（Linux）
- **每连接零堆分配** — 状态走栈
- **编译期优化** — 日志级别、SQL 模板、路由解析
- **连接池** — DB 复用 + 健康检查

详细基准：`zig build run-bench`

---

## 路线图

### v0.9（当前）— AI 协议层 ✅

- `zf --json` 机器可读 manifest
- `// ── ai-edit-zone: ...` 标记
- `zfinal.ZfTool` 进程内生成器
- AI 友好的 SQLite 约束错误
- 6 个 codegen 回归测试
- 5 个 skill 文件 + 1 个 sub-agent

### v1.0 — 稳定版

- [ ] 稳定 API（无重大变更）
- [ ] 全量集成测试套件
- [ ] 生产部署指南
- [ ] gRPC 支持（可选模块）
- [ ] 公开 demo 部署

---

## 贡献

1. Fork 仓库
2. 创建特性分支：`git checkout -b feature/amazing`
3. AI 智能体请读 `.claude/skills/zfinal-ai-playbook.md`
4. 改完跑测试：`zig build test && zig build test-zf`
5. 提交：`git commit -m 'feat: add amazing feature'`
6. 推送 + 开 PR

详见 [CONTRIBUTING.md](CONTRIBUTING.md)。

---

## 许可证

MIT — 见 [LICENSE](LICENSE)。

---

<div align="center">

Made with ❤️ by the ZFinal Team

**ZFinal v0.9.3** — Zig 的 AI 极速开发框架

</div>
