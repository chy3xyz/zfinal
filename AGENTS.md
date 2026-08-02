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
"AI: edit directly". Re-running generators **merges** matching
`// ── ai-edit-zone: <name>` bodies into the existing file. If no zones match,
new output goes to `<path>.gen.new` (use `--force` to overwrite everything).

## ❌ NEVER

- Write model/handler/service code from scratch — use `zf` tools
- Skip `zf check` before committing
- Skip the productized gate on framework PRs: `zig build gate` (or `zf gate`)

## 🔍 Self-audit

```bash
zf check               # scans for generated/edit boundary violations
zf check --deadcode    # unused decls / modules (zdeadcode); add --deadcode-warn for soft fail
zig build gate-quick   # day-to-day; full: zig build gate / zf gate
zf release-check       # before tagging vX.Y.Z (default --strict) — see doc/release_and_quality_gates.md
zf market search <q>   # local module catalog — see doc/module_marketplace.md
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
zig build test             # baseline: 257 passed; 11 skipped; 0 failed
zig build test -Ddriver_pg=true -Ddriver_mysql=true  # all drivers
zig build install-zf       # CLI tool → zig-out/bin/zf
zig build run-hello        # hello-world demo
zig build run-production   # production example (logging, metrics, CSRF)
zig build run-bench        # benchmark tool
zig build -Dlog-level=debug  # compile-time log level
```

## 📚 Full docs

- `doc/best_practices.md` — best-practice hub (task index + v0.20.x capability timeline)
- `doc/zent.md` — data layer B: `zfinal.zent` as alternative / primary vs `DB`/`Model`
- `doc/nats.md` — NATS connector (`QueueNatsClient`, zero dep)
- `doc/robustmq.md` — RobustMQ / Kafka connector (`QueueRobustMQClient`)
- `doc/architecture_best_practices.md` — code architecture best practices (layers, plugins, AI boundaries)
- `doc/api_envelope.md` — JSON response envelopes (REST/HttpError vs zapi; one style per module)
- `doc/scale_to_millions.md` — supporting ~10M users (topology, constraints, capacity)
- `doc/progressive_architecture.md` — L0→L3 progressive code architecture derived from scale plan
- `CHANGELOG.md` — version history
- `SECURITY.md` — security policy
- `PRODUCTION_AUDIT.md` — production readiness checklist
- `doc/ai.md` — business AI runtime (`zfinal.ai`: provider / skills / Agent)
- `doc/aichat.md` — AI migration prompt templates / ZfTool

Zig 0.17 specifics: `@cImport` removed → use `b.addTranslateC` in build.zig.
`std.fmt.bufPrintZ` → `bufPrint` + manual `buf[len]=0`.
`allocator.dupeZ` → `allocSentinel` + `@memcpy`.

## Learned User Preferences

- Prefer writing architecture / best-practice conclusions into `doc/` (not chat-only).
- Prefer graduating experimental plugins and queue clients into stable public API rather than leaving them under `experimental`.
- When asked to submit / commit / ship / 打 tag, create the git commit **and** annotated version tag, then **automatically** `git push origin <branch>` and `git push origin <tag>` (do not wait for a separate push ask).

## Learned Workspace Facts

- Sibling project `zigmodu` at `/Users/n0x/w4_proj/zig_ws/zigmodu` is the reference for connector patterns (Kafka → RobustMQ) and zent integration.
- Stable messaging surface targets formal `QueueNatsClient` and RobustMQ connectors, not long-lived experimental exports.
- Keep pace with the locally installed latest Zig 0.17-dev when upgrading compatibility.
