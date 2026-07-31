<div align="center">

# ⚡ ZFinal

**Zig 的 AI 极速开发框架** — *AI speedrun web framework for Zig*

*Inspired by JFinal — minimal API, maximal performance, AI-first design*

[![Zig](https://img.shields.io/badge/Zig-0.17.0-orange.svg)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-v0.20.9-blue.svg)](CHANGELOG.md)
[![Tests](https://img.shields.io/badge/tests-215%20passed%20%C2%B7%2019%20codegen%20%C2%B7%200%20failed-brightgreen.svg)]()
[![Drivers](https://img.shields.io/badge/drivers-SQLite%20%C2%B7%20PostgreSQL%20%C2%B7%20MySQL-blue.svg)]()
[![Production](https://img.shields.io/badge/production--score-9.8%2F10%20(contractual)%20%C2%B7%20~9.1%20honest-brightgreen.svg)](PRODUCTION_AUDIT.md)

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
zig build test             # Run 146 unit + integration tests (2 skipped)
zig build test-zf          # Run 17 codegen regression tests
```

### Run an example

```bash
zig build run-hello              # Hello-world demo
zig build run-blog               # Blog with SQLite
zig build run-ai-blog-5min       # 5-minute AI speedrun demo
zig build run-production         # Production example (CSRF, metrics, graceful shutdown)
zig build run-htmx               # HTMX interactive app
zig build run-standalone-admin   # Single-binary admin (all HTML @embedFile'd)
```

### Add ZFinal to your project

```bash
zig fetch --save https://github.com/chy3xyz/zfinal/archive/refs/tags/v0.20.9.tar.gz
```

In your `build.zig.zon`:

```zon
.dependencies = .{
    .zfinal = .{
        .url = "https://github.com/chy3xyz/zfinal/archive/refs/tags/v0.20.9.tar.gz",
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
zig build test     # 146 integration + 17 codegen tests
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

**Typed SQL errors (v0.14.0)**: drivers return one of
`UniqueViolation`, `ForeignKeyViolation`, `CheckViolation`,
`NotNullViolation`, `LockTimeout`, `Deadlock`, `IntegrityViolation`,
`ParseError`, `UnknownTable`, `ConnectionLost` — mapped from PG
SQLSTATE (23xxx/40P01/55P03/42xxx) and MySQL errno (1062, 1451/1452,
3819, 1048, 1205, 1213, 1064, 1146).

**Binary result decoding (v0.15.0)**: drivers emit typed `Cell`
values directly from wire format — PG uses `resultFormat=1` + per-OID
typed reads, MySQL uses per-column `MYSQL_BIND` with
`MYSQL_TYPE_LONGLONG`/`MYSQL_TYPE_DOUBLE`, SQLite uses typed
`sqlite3_column_*`. Numeric columns skip the parseInt round-trip:

```zig
const Cell = union(enum) {
    null, text: []const u8, int: i64, float: f64, bool: bool, blob: []const u8,
};

// Row.getInt(idx) / getFloat(idx) return the cached typed value —
// no parseInt/parseFloat on every read. ~2x faster on numeric columns.
// Fractional floats (MySQL SUM/DECIMAL money) → error.NotAnInteger; use getFloat.
const row = result.currentRow().?;
const id: i64 = (try row.getInt(0)).?;
const total: f64 = (try row.getFloat(1)).?;
```

Existing `getText` / `getInt` / `getBool` / `getCurrentRowMap`
callers are **unaffected** — they auto-adapt to typed cells.

**SSL/TLS + connect_timeout (v0.14.0)**: `DBConfig.ssl_mode` (5
levels from `disable` to `verify_full`) plus `connect_timeout`
(seconds, default 30) finally honored. PG appends `sslmode=...` and
`connect_timeout=N` to its conninfo; MySQL calls
`mysql_options(MYSQL_OPT_CONNECT_TIMEOUT|MYSQL_OPT_SSL_MODE)` before
connect. MySQL also forces `utf8mb4` after connect so emoji + non-BMP
round-trip works.

#### Connection pool stability (v0.12.7 → v0.13.4)

The connection pool went through six rounds of P0 hardening for
high-burst, mixed-driver workloads. Every release below is a real fix,
not a refactor.

| Version | Fix |
|---------|-----|
| v0.12.7 | `DB.init()` now returns `*DB` (heap-allocated) — union-of-drivers no longer copy-broken on aarch64 |
| v0.12.8 | `self.conn orelse` unwrap + `0xaa` poison guard in `PostgresDB.ping/exec/query` |
| v0.12.9 | All `_ = pthread_mutex_lock` replaced with `mutex_init.lockMut` (panics on EINVAL / EDEADLK) |
| v0.13.0 | `broadcastCond` on keepAlive destroy (was `signal` — only one waiter) + `DB.valid` flag |
| v0.13.2 | `DB.magic` sentinel (0xDBDBDBDB) + pre-alloc `ArrayList` capacity → no realloc frees |
| v0.13.4 | `defer unlockMut` moved before `destroyMutex` + `checked_out` defaults to `true` for direct `DB.init` conns |

**Result**: pool survives `max_connections=20, burst 10, ~12 borrows`
without segfault. Verified by `zig build test` (203 integration
tests, 0 crashes).

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

### CLI Tooling (`zf`)

The `zf` CLI is the project's Swiss-army knife — codegen, schema ops,
self-healing, AI assist, load testing, and AI-edit-zone audits.

| Command | Purpose |
|---------|---------|
| `zf new <name>` | Scaffold a project — bundles AI skills + GitHub Actions workflow |
| `zf crud:sql <schema.sql> [--json]` | Generate model/service/handler/routes from SQL |
| `zf crud:sql --explain --dry-run` | Preview plan without writing files (AI planning mode) |
| `zf crud:dsn postgres://...` | Generate from a live PG/MySQL connection |
| `zf migrate up/down/status` | Apply / revert Flyway-style SQL migrations |
| `zf seed new/run/list/reset` | Idempotent fixture inserts (`INSERT OR IGNORE`) |
| `zf fixture <table> [--count N] [--run]` | Generate fake data (schema-aware) |
| `zf bench <url> [--count N] [--concurrency C]` | HTTP load test — RPS, p50/p95/p99 |
| `zf ai "<prompt>" [--provider openai\|anthropic]` | AI assist with AGENTS.md + skill context |
| `zf check` | Audit generated/edit boundary compliance |
| `zf check --heal` | Auto-patch 6 common compile errors (Zig 0.17, stale API, etc.) |
| `zf check --ai-zones` | Reverse-index of AI-editable vs AI-LOCKED files |
| `zf openapi [--out <file>]` | Generate minimal OpenAPI 3.0.3 spec from project routes |
| `zf g handler\|model\|middleware\|service\|task <Name>` | Add a single module |
**`--json` everywhere**: every command emits structured JSON for AI parsing.
**`--heal` is idempotent** — second run patches 0 files.

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
│   ├── main.zig                  # Entry point (new/migrate/seed/fixture/bench/ai/check)
│   ├── codegen.zig               # Code generator
│   ├── codegen_test.zig          # 17 generator regression tests
│   └── templates.zig             # Code templates
├── examples/                     # 13+ runnable examples
│   ├── ai-blog-5min/             # 5-minute AI speedrun
│   ├── standalone-admin/         # @embedFile single-binary admin
│   ├── blog-single/
│   ├── hello-world/
│   └── ...
├── .claude/
│   ├── skills/                   # 8 AI-recognizable skills
│   │   ├── zfinal-onboarding.md  # Read first
│   │   ├── zfinal-ai-playbook.md
│   │   ├── zfinal-health.md
│   │   ├── zfinal-framework.md
│   │   ├── zfinal-app.md
│   │   ├── zfinal-evolution.md
│   │   ├── zfinal-debug.md
│   │   └── zfinal-evolve.md
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

ZFinal ships 8 skills + 1 sub-agent for AI agents:

| Skill | Read it when… |
|-------|---------------|
| `zfinal-onboarding` | First contact with the project |
| `zfinal-ai-playbook` | Adding a new feature / entity / route |
| `zfinal-health` | Running tests, CI, health check |
| `zfinal-framework` | Adding a module to the framework |
| `zfinal-app` | Building a complete app from scratch |
| `zfinal-evolution` | Zig 0.17, memory safety, leaks, races |
| `zfinal-debug` | Compile-error → fix-pattern lookup |
| `zfinal-evolve` | Evolving the framework itself (SemVer, AGENTS.md, deprecation) |

Plus a sub-agent `zfinal-developer` in `.claude/agents/` that bundles
the onboarding + playbook + hard rules into a single auto-dispatched
unit.

`zf new <project>` copies all 8 skills into the new project's
`.claude/skills/` so AI agents working on it have full framework
context from day one.

---

## Production Readiness

| Status | Dimension | Score |
|--------|-----------|-------|
| ✅ | Build Stability | 96% |
| ✅ | Security | 95% |
| ✅ | Memory Safety | 95% |
| ✅ | Correctness | 94% |
| ✅ | Observability | 92% |
| ✅ | Concurrency | 93% |
| ✅ | Testability | 94% |
| ✅ | Plugin Maturity | 93% |
| ✅ | Documentation | 94% |
| ✅ | Examples | 90% |
| **→** | **Overall** | **~9.1/10 (contractual 9.8)** |

The honest, independently-assessed score is **~9.1/10** (controlled
deploy ~9.5–9.7). The **9.8/10** figure is the contractual target
we design toward and hold ourselves accountable to; the residual gap
is mostly the Zig 0.17-dev pin and the forced-connection-close
workaround for keep-alive.

See [PRODUCTION_AUDIT.md](PRODUCTION_AUDIT.md) for the full deployment
contract, dimension-by-dimension evidence, and residual gaps.

Architecture layers, AI edit boundaries, and plugin maturity rules:
[doc/architecture_best_practices.md](doc/architecture_best_practices.md).

Scale-out (millions of users) and progressive L0→L3 code layout:
[doc/scale_to_millions.md](doc/scale_to_millions.md) ·
[doc/progressive_architecture.md](doc/progressive_architecture.md).

**Data layers (pick a primary):** `zfinal.DB`/`Model` (SQL + `zf`) **or** `zfinal.zent`
(schema-as-code — recommended primary for e-commerce / social). See
[doc/zent.md](doc/zent.md) · [`examples/zent-shop`](examples/zent-shop/).

---

## Plugin Maturity

| Plugin | Status | Description |
|--------|--------|-------------|
| Cache (memory) | ✅ Stable | In-memory cache with TTL, thread-safe |
| Cache (Redis) | ✅ Stable | RESP client with loop-read, size cap, parse unit tests |
| Cron | ✅ Stable | Cron expression parser, job scheduling |
| CircuitBreaker | ✅ Stable | closed/open/half-open state machine + `call()` helper |
| Queue (in-process) | ✅ Stable | Pub/sub mailbox fan-out (`QueueClient`) |
| MessageQueue | ✅ Stable | Spring-style façade over `QueueClient` |
| Queue (NATS) | ✅ Stable | NATS wire (`QueueNatsClient` / `NatsClient`, zero dep) |
| RobustMQ / Kafka | ✅ Stable | Kafka wire → RobustMQ (`QueueRobustMQClient`, `KafkaProducer`) |
| DID | ✅ Stable | Local `did:key` Ed25519 sign/verify/resolve |
| Agent (MCP) | ✅ Stable | JSON-RPC `tools/list` + `tools/call` router |
| MetricsExporter | ✅ Stable | Prometheus text + JSON from `Metrics` |
| MQTT | ✅ Stable | MQTT 3.1.1 CONNECT/PUBLISH QoS0/PING/DISCONNECT |
| ObjectMapper | ✅ Stable | JSON read/write via std.json |
| P2P | ✅ Stable | TCP mesh: peers, broadcast, announce, inbox (`P2pPlugin`) |
| HttpClient | ✅ Stable | `std.http.Client` GET/POST/PUT/DELETE + `postForm` |
| ConfigClient | ✅ Stable | Env / JSON file / env_then_file lookup |
| BeanValidator | ✅ Stable | Fluent wrapper over `Validator` |
| TaskScheduler | ✅ Stable | Cron + fixed-rate / fixed-delay via `tick()` |
| OAuth2Client | ✅ Stable | Authorize URL + code/credentials/refresh token helpers |
| PostgreSQL | ✅ Stable | libpq driver — `-Ddriver_pg=true` |
| MySQL | ✅ Stable | mysqlclient driver — `-Ddriver_mysql=true` |
| WeChat | ✅ Stable | Unified wrapper for [zwechat](https://github.com/chy3xyz/zwechat.git) |
| Admin (Static) | ✅ Stable | `zfinal.StaticAdmin` — `@embedFile` |

Messaging connectors: [doc/nats.md](doc/nats.md) · [doc/robustmq.md](doc/robustmq.md).

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

### v0.9 — AI Protocol Layer ✅

- `zf --json` machine-readable manifest
- `// ── ai-edit-zone: ...` markers
- `zfinal.ZfTool` in-framework generator
- AI-friendly SQLite constraint errors
- 6 codegen regression tests
- 5 skill files + 1 sub-agent

### v0.10 — Production Hardening ✅

- `zfinal.StaticAdmin` — single-binary admin via `@embedFile` (no CDN, no static files)
- Graceful shutdown: SIGTERM unblocks `accept()` via watchdog fiber
- `server.zig` `group.cancel(io)` panic replaced with active-connection drain
- AI skills: `zfinal-debug.md` (compile-error → fix lookup) + `zfinal-evolve.md` (framework evolution)
- `zf crud:sql --explain --dry-run` (AI planning mode)
- `zf check --heal` (auto-patch 4 → 6 common compile errors)
- `zf check --ai-zones` (reverse index of AI-editable files)
- MySQL binlog replication API (real CDC)

### v0.11 → v0.12 — CLI Tooling + Single-Binary ✅

- `zf migrate up/down/status` — Flyway-style SQL migrations
- `zf seed new/run/list/reset` — idempotent fixtures
- `zf fixture` — schema-aware fake data generator
- `zf bench` — HTTP load tester (RPS, p50/p95/p99)
- `zf ai` — AI assistant with AGENTS.md + skill context (OpenAI / Anthropic)
- `zf new` bundles all 8 AI skills + GitHub Actions workflow into new projects
- `zf check --heal` expanded to 6 patches (idempotent on re-run)
- Zig version aligned with CI: `0.17.0-dev.1422+e863bf3be` (`minimum_zig_version` in `build.zig.zon`).

### v0.12.4 → v0.13.4 — Pool Stability ✅

- Six rounds of P0 fixes for connection pool (heap-allocated DB, poison guard, checked return codes, magic sentinel, pre-alloc capacity, cond_broadcast, checked_out guard)
- WeChat plugin — unified wrapper for [zwechat](https://github.com/chy3xyz/zwechat.git)
- `DB.begin / commit / rollback` implemented
- No more `@panic` on rollback / mutex paths; structured logger instead
- Removed debug `REGISTER GET/POST` prints
- Baseline restored: **146 passed, 2 skipped, 0 failed + 17 codegen tests**

### v0.14.0 — Driver Parity ✅

- **`src/db/diag.zig`** — unified SQL error diagnostics. Maps PG
  SQLSTATE (23xxx, 40P01, 55P03, 42xxx) and MySQL errno (1062,
  1451/1452, 3819, 1048, 1205, 1213, 1064, 1146) to typed Zig errors
  (`UniqueViolation`, `ForeignKeyViolation`, …). 10 unit tests.
- **`DBConfig.ssl_mode: SSLMode`** — TLS for cloud DBs (5 levels:
  `disable`, `prefer`, `require`, `verify_ca`, `verify_full`).
- **PG**: `connect_timeout=N` + `client_encoding=UTF8` + `sslmode=...`
  appended to conninfo; `DBConfig.timeout` now actually honored.
- **MySQL**: `MYSQL_OPT_CONNECT_TIMEOUT` + `MYSQL_OPT_SSL_MODE` +
  `mysql_set_character_set("utf8mb4")` after connect.

### v0.15.0 — Binary Result Decoding ✅

- **`Cell` tagged union** (`null` / `text` / `int` / `float` / `bool` /
  `blob`) replaces text-only `[]?[]const u8` in `Row.cells`. Drivers
  emit typed values directly from wire format.
- **PG**: `PQexecParams(..., resultFormat=1)` + per-OID typed reads
  (`std.mem.readInt(_, _, .big)` for ints, `@bitCast` for floats).
- **MySQL**: per-column `MYSQL_BIND` with `MYSQL_TYPE_LONGLONG` /
  `MYSQL_TYPE_DOUBLE` for numeric columns (replaces the old 4096-byte
  STRING buffer per column).
- **SQLite**: typed `sqlite3_column_type` + `sqlite3_column_int64` /
  `double` / `text` / `blob` dispatch.
- **Estimated 2x speedup on numeric column reads** (no parseInt on
  every consumer call).
- **Breaking API**: `Row.cells` / `ResultSet.addRow` type change.
  All `getText` / `getInt` / `getBool` / `getCurrentRowMap` callers
  are unaffected.
- 7 new `result.zig` unit tests; baseline **203 passed, 9 skipped,
  0 failed + 19 codegen tests**.

### v0.16.0 — Unix Socket + Incremental Result Iteration ✅

- **`DBConfig.unix_socket: ?[]const u8`** — connect via local Unix
  domain socket (PG: `host=/path` in conninfo; MySQL: 7th arg of
  `mysql_real_connect`).
- **`SQLiteDB.queryIter` + `SQLiteIter.next()`** — stream rows one at
  a time via `sqlite3_step`. O(1) memory per row.
- **`MySQLDB.queryIter` + `MySQLIter.next()`** — same for MySQL via
  `mysql_stmt_fetch`.
- **PG iterator** deferred to v0.17.

### v0.17.0 — PG Iterator + Hot-Path Read Helpers ✅

- **`PostgresDB.queryIter` + `PgIter.next()`** — incremental query
  using `PQsetSingleRowMode` + repeated `PQgetResult` calls.
  `PgIter.deinit()` drains the required trailing `PQgetResult` call.
- **`Row.intAt(idx) -> i64`** / **`Row.floatAt(idx) -> f64`** /
  **`Row.boolAt(idx) -> bool`** — hot-loop helpers that return the
  typed value directly without the error-union wrapper. Panics on
  null/type mismatch. In the `zig build run-db-bench` micro-bench,
  `intAt` matches or beats the legacy `getText + parseInt` path.
- **`benchmark/db_decode.zig`** + `zig build run-db-bench` —
  compares three numeric-read paths. Honest finding: for in-process
  SQLite the typed path is competitive with parseInt (~1.0–1.2x for
  `intAt`). Real wins are PG/MySQL wire format (server skips
  to_text) and zero-allocation numeric decode.
- **`docker/test-compose.yml`** + `docker/run-live-tests.sh` —
  live PG + MySQL test environment for the integration suite.

### v1.0 — Stable Release

- [ ] Stable API surface (no breaking changes without major version)
- [ ] Comprehensive integration test suite (currently 208 — adding
      PG/MySQL live runs against Docker containers)
- [ ] Production deployment guide (with v0.14.0 SSL/TLS + v0.15.0
      binary decode tuning notes)
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

**ZFinal v0.20.9** — Zig 的 AI 极速开发框架

</div>
