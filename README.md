<div align="center">

# ⚡ ZFinal

**Zig 的 AI 极速开发框架** — *AI speedrun web framework for Zig*

*Inspired by JFinal — minimal API, maximal performance, AI-first design*

[![Zig](https://img.shields.io/badge/Zig-0.17.0-orange.svg)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-145%20passing%2C%200%20leaks-brightgreen.svg)]()
[![Codegen](https://img.shields.io/badge/codegen%20tests-6%2F6-brightgreen.svg)]()
[![Production](https://img.shields.io/badge/production--readiness-92%25-green.svg)](PRODUCTION_AUDIT.md)

**English** | [中文文档](README_CN.md)

</div>

---

## 🤖 If you are an AI agent

> **Read `.claude/skills/zfinal-onboarding.md` first** — a 30-second
> orientation that tells you the 5-command speedrun, which skill to
> load next, and what you must never do (e.g. hand-write `model.zig`).

ZFinal is the **first Zig web framework designed AI-first**. The CLI
emits machine-readable JSON, generated files contain
`// ── ai-edit-zone: ...` markers, and the in-framework `ZfTool` lets
you invoke the generator from code.

| Step | Command | Time |
|------|---------|------|
| 1 | `cat schema.sql` | 5 s |
| 2 | `zf crud:sql schema.sql --json` | 2 s |
| 3 | Edit `ai-edit-zones` in the generated files | 2 min |
| 4 | `zf check && zig build test` | 5 s |
| 5 | `zig build run` | 1 s |

**5 commands. 5 minutes. Full CRUD + tests + manifest.**

---

## What is ZFinal?

A high-performance, production-grade Zig web framework with the usual
features (router, ORM, CSRF, captcha, i18n, WebSocket, plugins,
metrics) — and one property no other Zig web framework has:
**AI-native tooling**. The `zf` CLI is designed so an AI agent can
add a feature without reading the working tree.

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
    try ctx.renderJson(.{ .message = "Hello, ZFinal!" });
}
```

---

## Why ZFinal is different

| | Other Zig web frameworks | ZFinal |
|---|--------------------------|--------|
| Code generation | None — hand-write everything | `zf crud:sql` emits model/service/handler/routes in 1 command |
| AI contract | No boundary — AI invents patterns | `// ── ai-edit-zone: ...` markers tell the AI exactly where to edit |
| Machine output | None — AI must grep | `zf --json` emits structured manifest (tables, files, fields, next steps) |
| In-framework | AI must shell out to invoke | `zfinal.ZfTool` callable from any Zig code |
| Self-check | None | `zf check` audits AI boundary compliance |

---

## Quick Start

### Build from source

```bash
git clone https://github.com/chy3xyz/zfinal.git
cd zfinal
zig build                  # Build framework + all examples
zig build test             # Run 145 unit + integration tests
zig build test-zf          # Run 6 codegen regression tests
```

### Run an example

```bash
zig build run-hello              # Hello-world demo
zig build run-blog               # Blog with SQLite
zig build run-ai-blog-5min       # 5-minute AI speedrun demo
zig build run-production         # Production example
zig build run-htmx               # HTMX interactive app
```

### Add ZFinal to your project

```bash
zig fetch --save https://github.com/chy3xyz/zfinal/archive/refs/tags/v0.9.3.tar.gz
```

In your `build.zig.zon`:

```zon
.dependencies = .{
    .zfinal = .{
        .url = "https://github.com/chy3xyz/zfinal/archive/refs/tags/v0.9.3.tar.gz",
        .hash = "...",  // auto-filled by `zig fetch`
    },
},
```

In your `build.zig`:

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

Or use a local path for development:

```zon
.zfinal = .{ .path = "../zfinal" },
```

---

## The AI speedrun (long form)

### Step 1 — Schema is the source of truth

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

### Step 2 — One command generates everything

```bash
zf crud:sql schema.sql --json
```

Output (parsed by an AI):

```json
{
  "tables": [
    {
      "name": "users",
      "files": { "model": "users/model.zig", "service": "users/service.zig", "handler": "users/handler.zig", "routes": "users/routes.zig" },
      "ai_edit_zones": [
        { "file": "service.zig", "purpose": "business rules beyond CRUD" },
        { "file": "handler.zig", "purpose": "auth + response shaping" }
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

### Step 3 — Edit only inside `ai-edit-zones`

```zig
// ── ai-edit-zone: business rules ─────────────
pub fn isUsernameTaken(db: *zfinal.DB, username: []const u8) !bool {
    // AI writes this
}
// ──────────────────────────────────────────────
```

### Step 4 — Verify

```bash
zf check           # AI boundary audit
zig build test     # 145+ tests
```

### Step 5 — Run

```bash
zig build run
```

Full walkthrough: [doc/ai-quickstart.md](doc/ai-quickstart.md).
Runnable demo: [`examples/ai-blog-5min/`](examples/ai-blog-5min/ZF_GEN.md).

---

## Core Capabilities

### Routing + Interceptors

```zig
try app.get("/users/:id", showUser);
try app.post("/users", createUser);
try app.put("/users/:id", updateUser);
try app.delete("/users/:id", deleteUser);

var api = zfinal.RouteGroup.init(&app, "/api");
try api.get("/health", healthHandler);

try app.addGlobalInterceptor(zfinal.CORSInterceptor);
```

### Database + ORM

```zig
const User = struct { id: ?i64, name: []const u8, email: []const u8 };
const UserModel = zfinal.Model(User, "users");

var pool = zfinal.ConnectionPool.init(allocator, config, 10);

const users = try UserModel.findAll(&db, allocator);
var user = UserModel.Instance{ .data = .{ .name = "Alice", .email = "alice@example.com" } };
try user.save(&db);
```

**AI-friendly errors**: constraint violations return typed errors like
`UniqueViolation` with `table` and `column` extracted, so an AI can
show "users.email already exists" instead of "SQLite step failed: 19".

### Security

- CSRF token (32-byte CSPRNG, Base64, one-time, auto-expiry)
- Rate limiting (real socket address, not spoofable headers)
- CAPTCHA (numeric, alpha, alphanumeric, math)
- Parameterized SQL everywhere — no string interpolation

### In-framework AI

```zig
const zfinal = @import("zfinal");
const tool = zfinal.ZfTool.init(allocator);

// Same manifest as `zf crud:sql --json`, callable from Zig code:
const manifest = try tool.manifestFromSql(schema_text);
defer allocator.free(manifest);

// Build a system prompt for an AI agent that knows this project's schema:
const prompt = try tool.buildAgentSystemPrompt(schema_text);
defer allocator.free(prompt);
```

---

## Project Structure

```
zfinal/
├── src/                          # Framework source
│   ├── main.zig                  # Public API
│   ├── core/                     # Server, Router, Context
│   ├── db/                       # DB + drivers + ORM
│   ├── interceptor/              # Auth, CORS, CSRF
│   ├── plugin/                   # Cache, Cron, Redis
│   ├── kit/                      # 17 utility kits
│   ├── aichat/                   # AI client + ZfTool
│   └── io_instance.zig           # Global Io + allocator
├── tools/zf/                     # CLI tool
│   ├── main.zig                  # Entry point
│   ├── codegen.zig               # Code generator
│   ├── codegen_test.zig          # 6 generator regression tests
│   └── templates.zig             # Code templates
├── examples/                     # 10+ runnable examples
│   ├── ai-blog-5min/             # 5-minute AI speedrun
│   ├── blog-single/
│   ├── hello-world/
│   └── ...
├── .claude/
│   ├── skills/                   # AI-recognizable skills
│   │   ├── zfinal-onboarding.md  # Read first
│   │   ├── zfinal-ai-playbook.md
│   │   ├── zfinal-health.md
│   │   ├── zfinal-framework.md
│   │   ├── zfinal-app.md
│   │   └── zfinal-evolution.md
│   └── agents/
│       └── zfinal-developer.md   # Sub-agent definition
├── doc/                          # AI-targeted documentation
│   ├── index.md                  # Dual-audience landing page
│   ├── ai-quickstart.md          # 5-minute walkthrough
│   └── ...
├── AGENTS.md                     # AI-first rules (read first)
├── CLAUDE.md                     # Health Stack + skill routing
└── build.zig                     # Build configuration
```

---

## AI Skill Set

ZFinal ships 6 skills + 1 sub-agent for AI agents:

| Skill | Read it when… |
|-------|---------------|
| `zfinal-onboarding` | First contact with the project |
| `zfinal-ai-playbook` | Adding a new feature / entity / route |
| `zfinal-health` | Running tests, CI, health check |
| `zfinal-framework` | Adding a module to the framework |
| `zfinal-app` | Building a complete app from scratch |
| `zfinal-evolution` | Zig 0.17, memory safety, leaks, races |

Plus a sub-agent `zfinal-developer` in `.claude/agents/` that bundles
the onboarding + playbook + hard rules into a single auto-dispatched
unit.

---

## Production Readiness

| Status | Dimension | Score |
|--------|-----------|-------|
| ✅ | Build Stability | 95% |
| ✅ | Security | 90% |
| ✅ | Memory Safety | 88% |
| ✅ | Correctness | 88% |
| ✅ | Observability | 85% |
| ✅ | Concurrency | 85% |
| ✅ | Testability | 85% |
| ✅ | Code Quality | 85% |
| 🟡 | Documentation | **85%** (was 60%, AI-targeted rewrite) |
| 🟡 | Examples | 82% |
| **→** | **Overall** | **92%** |

See [PRODUCTION_AUDIT.md](PRODUCTION_AUDIT.md) for the full assessment.

---

## Plugin Maturity

| Plugin | Status | Description |
|--------|--------|-------------|
| Cache (memory) | ✅ Stable | In-memory cache with TTL, thread-safe |
| Cache (Redis) | ✅ Stable | Full Redis client with RESP protocol over TCP |
| Cron | ✅ Stable | Cron expression parser, job scheduling |
| PostgreSQL | 🔧 Opt-in | libpq driver — `-Ddriver_pg=true` |
| MySQL | 🔧 Opt-in | mysqlclient driver — `-Ddriver_mysql=true` |
| MQTT | 🟡 Stub | MQTT 3.1.1 client — IoT, not core |
| Agent (MCP) | 🔧 Experimental | Model Context Protocol agent |
| P2P | 🔧 Experimental | Peer-to-peer networking |
| DID | 🔧 Experimental | Decentralized Identity |

---

## Performance

Benchmark characteristics (M1 Pro, 8 cores, localhost):

| Scenario | Throughput | Latency (P50) | Memory |
|----------|-----------|---------------|--------|
| Hello world (JSON) | ~25,000 req/s | 0.4ms | ~12MB |
| SQLite read (cached) | ~15,000 req/s | 0.6ms | ~14MB |
| SQLite write (pooled) | ~5,000 req/s | 1.2ms | ~14MB |
| 1,000 concurrent keep-alive | ~30,000 req/s | 0.5ms | ~18MB |

- **Zero GC pauses** — no garbage collector
- **Fiber-based concurrency** — kqueue (macOS) / io_uring (Linux)
- **Zero heap allocation per connection** — stack-resident state
- **Compile-time optimization** — log levels, SQL templates, route parsing
- **Connection pooling** — database reuse with health checks

For detailed benchmarks: `zig build run-bench`

---

## Roadmap

### v0.9 (current) — AI Protocol Layer ✅

- `zf --json` machine-readable manifest
- `// ── ai-edit-zone: ...` markers
- `zfinal.ZfTool` in-framework generator
- AI-friendly SQLite constraint errors
- 6 codegen regression tests
- 5 skill files + 1 sub-agent

### v1.0 — Stable Release

- [ ] Stable API surface (no breaking changes without major version)
- [ ] Comprehensive integration test suite
- [ ] Production deployment guide
- [ ] gRPC support (optional module)
- [ ] Live demo deployment

---

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/amazing`
3. Read `.claude/skills/zfinal-ai-playbook.md` (AI agents)
4. Make changes, run tests: `zig build test && zig build test-zf`
5. Commit: `git commit -m 'feat: add amazing feature'`
6. Push and open a Pull Request

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines.

---

## License

MIT — see [LICENSE](LICENSE) for details.

---

<div align="center">

Made with ❤️ by the ZFinal Team

**ZFinal v0.9.3** — Zig 的 AI 极速开发框架

</div>
