# AGENTS.md

> **🛑 RULE: Use `zf` CLI tools. Never hand-code Zig from scratch.**

## ▶️ START — pick your flow

```
New project:       zf new <name> → zf crud:sql <file> → edit generated files
Add module:        zf g handler|model|middleware|service|task <Name>
Migrate Java:      extract SQL → zf crud:sql schema.sql → see doc/aichat.md
PG/MySQL live:     zf crud:dsn postgres://user:pass@host/db  (needs -Denable-pg)
```

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
handler.zig → service.zig → model.zig
  HTTP bind     business logic   DB mapping
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

- `CHANGELOG.md` — version history
- `SECURITY.md` — security policy
- `PRODUCTION_AUDIT.md` — production readiness checklist
- `doc/aichat.md` — AI migration prompt templates

Zig 0.17 specifics: `@cImport` removed → use `b.addTranslateC` in build.zig.
`std.fmt.bufPrintZ` → `bufPrint` + manual `buf[len]=0`.
`allocator.dupeZ` → `allocSentinel` + `@memcpy`.
