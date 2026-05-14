# AGENTS.md

> **🛑 RULE: Use `zf` CLI tools. Never hand-code Zig from scratch.**

## ▶️ START — pick your flow

```
New project:       zf new <name> → zf crud:sql <file> → edit ext/*.zig
Add module:        zf g handler|model|middleware|service|task <Name>
Migrate Java:      extract SQL → zf crud:sql schema.sql → see doc/ai_migration_prompts.md
PG/MySQL live:     zf crud:dsn postgres://user:pass@host/db  (needs -Denable-pg)
```

## 📂 EDIT ZONE — only these are safe

```
✅ ext/*.zig           AI business logic (never overwritten)
✅ src/routes.zig      register new handlers
✅ src/App.zig         add middleware
✅ src/common/         constants, errors
❌ *.gen.zig           overwritten on regeneration — DO NOT TOUCH
```

Token-efficient: `find . -path '*/ext/*.zig' -type f` → all editable files in one read.

## ❌ NEVER

- Write model/handler/service code from scratch — use `zf` tools
- Edit any `.gen.zig` file
- Put business logic outside `ext/`
- Skip `zf check` before committing

## 🔍 Self-audit

```bash
zf check    # scans for .gen.zig edits, code outside ext/, missing files
```

## 🏗️ Architecture (3 layers)

```
handler.gen.zig → service.gen.zig → model.gen.zig
   HTTP bind        business logic      DB mapping
```

## 📁 Generated module layout

```
src/modules/<sub>/<name>/
├── model.gen.zig       # zf crud:sql — DO NOT EDIT
├── service.gen.zig     # zf crud:sql — DO NOT EDIT
├── handler.gen.zig     # zf crud:sql — DO NOT EDIT
├── routes.zig
└── ext/                # ← AI writes here only
```

## 🔧 Build

```bash
zig build              # framework + examples
zig build test         # unit tests
zig build install-zf   # CLI tool → zig-out/bin/zf
```

## 📚 Full docs

- `doc/ai_migration_prompts.md` — Java→Zig prompt templates
- `doc/java_migration.md` — step-by-step migration guide
- `CHANGELOG.md` — version history
- `SECURITY.md` — security policy

Zig 0.16 specifics: `std.Io` (capital I), `ArrayList.empty` (no allocator), `append(a, item)`.
