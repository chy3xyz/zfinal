# AGENTS.md

> **🤖 ZFinal is an AI-first Zig web framework.**
> Optimized for AI-driven development: the `zf` CLI emits machine-readable
> JSON manifests, generated files contain `// ── ai-edit-zone: ...`
> markers telling you exactly where to write business logic, and the
> in-framework `zfinal.aichat.ZfTool` lets you invoke generators from code
> (`manifestFromSql` **and** `manifestFromZent`).
> When you (an AI agent) start a ZFinal task, read
> `.claude/skills/zfinal-onboarding.md` first. For graphs / e-commerce,
> load `.claude/skills/zfinal-zent-ai.md`.

> **🛑 RULE: Use `zf` CLI tools. Never hand-code Zig from scratch.**

## ▶️ START — pick your flow

```
# Data layer A (SQL primary): DB / Model + zf
New project:       zf new <name> → zf crud:sql <file> → edit generated files
Add module:        zf g handler|model|middleware|service|task <Name>
Migrate Java:      extract SQL → zf crud:sql schema.sql → see doc/aichat.md
PG/MySQL live:     zf crud:dsn postgres://user:pass@host/db  (needs -Denable-pg)

# Data layer B (zent primary): schema-as-code — e-commerce / social / RBAC
zf crud:zent schema.zent --json   # see doc/zent.md + examples/zent-shop
```

## 💾 Data layers — two alternatives

| Primary | Export | Use when |
|---------|--------|----------|
| **A. SQL** | `zfinal.DB` / `Model` | Flat CRUD, existing SQL, `zf crud:sql` |
| **B. zent** | `zfinal.zent` | Dense graphs, privacy, hooks — **can be the whole app's main ORM** |

Pick **one stack per module**. Do not mix drivers in one transaction. Details: `doc/zent.md`.

## 📂 EDIT ZONE — only these are safe

```
✅ src/modules/*/handler.zig    AI: add custom routes, middleware logic
✅ src/modules/*/service.zig    AI: add business logic, validation
✅ src/modules/*/model.zig      AI: add custom queries, computed fields
```

Generated files have `// @generated` header — safe to edit when header says
"AI: edit directly". Regeneration preserves hand-edited code.

## ❌ NEVER

- Write model/handler/service code from scratch — use `zf` tools
- Skip `zf check` before committing

## 🔍 Self-audit

```bash
zf check    # scans for generated/edit boundary violations
```

## 🏗️ Architecture (3 layers)

```
handler.zig → service.zig → model / persistence
  HTTP bind     business logic   DB/Model  或  zent Schema（二选一主力）
```

## 📁 Generated module layout

```
src/modules/<sub>/<name>/
├── model.zig        # zf crud:sql — struct, ORM, validate, fieldMap
├── service.zig      # zf crud:sql — CRUD, count, field merge
├── handler.zig      # zf crud:sql — HTTP, CSRF, rate limiting, parseId
└── routes.zig       # route registration for app
```

## 🔧 Build

```bash
zig build                  # framework + all examples
zig build test             # 142 unit tests (0 leaks)
zig build test -Ddriver_pg=true -Ddriver_mysql=true  # all drivers
zig build install-zf       # CLI tool → zig-out/bin/zf
zig build run-hello        # hello-world demo
zig build run-production   # production example (logging, metrics, CSRF)
zig build run-bench        # benchmark tool
zig build -Dlog-level=debug  # compile-time log level
```

## 📚 Full docs

- `doc/zent.md` — data layer B: `zfinal.zent` as alternative / primary vs `DB`/`Model`
- `doc/nats.md` — NATS connector (`QueueNatsClient`, zero dep)
- `doc/robustmq.md` — RobustMQ / Kafka connector (`QueueRobustMQClient`)
- `doc/architecture_best_practices.md` — code architecture best practices (layers, plugins, AI boundaries)
- `doc/scale_to_millions.md` — supporting ~10M users (topology, constraints, capacity)
- `doc/progressive_architecture.md` — L0→L3 progressive code architecture derived from scale plan
- `CHANGELOG.md` — version history
- `SECURITY.md` — security policy
- `PRODUCTION_AUDIT.md` — production readiness checklist
- `doc/aichat.md` — AI migration prompt templates

Zig 0.17 specifics: `@cImport` removed → use `b.addTranslateC` in build.zig.
`std.fmt.bufPrintZ` → `bufPrint` + manual `buf[len]=0`.
`allocator.dupeZ` → `allocSentinel` + `@memcpy`.
