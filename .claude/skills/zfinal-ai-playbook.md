---
name: zfinal-ai-playbook
description: Use when developing a ZFinal web app and you need to know the exact sequence of `zf` commands and file edits. Triggers on "new feature in zfinal", "add a model/handler", "regenerate from SQL", or any task that combines `zf` CLI with hand-written business logic. For zent/graph domains prefer zfinal-zent-ai.
---

# ZFinal AI Playbook — Standard Script

The complete sequence an AI follows to add a feature in a ZFinal app.

> **Graph / e-commerce / social?** Load **`zfinal-zent-ai`** instead and use
> `zf crud:zent`. This playbook is the **SQL / DB primary** path.

## 1. Read the situation

Before invoking any `zf` command:

- Read `CLAUDE.md` and `AGENTS.md`.
- Pick data-layer primary: **A) DB/Model** (this doc) or **B) zent** (`zfinal-zent-ai`).
- Identify schema source: `.sql`, live DSN, or `.zent`/JSON.

## 2. Generate (SQL primary)

```bash
zf crud:sql schema.sql [project_name] [--force] [--json]
```

Always use `--json`. Parse `tables[].files`, `ai_edit_zones`, `fields`, `next_steps`.

### zent primary (pointer)

```bash
zf crud:zent schema.zent --json
# details: .claude/skills/zfinal-zent-ai.md
```

## 3. Edit inside the AI edit zones

```zig
// ── ai-edit-zone: business rules ─────────────
```

- `service.zig` — validation, computed fields
- `handler.zig` — auth, response shaping
- `model.zig` — rare hooks

Keep edits small.

## 4. Single-file generators

```bash
zf g handler <Entity> [--json]
zf g service <Entity> [--json]
zf g middleware <Name>
zf g task <Name>
```

## 5. Verify

```bash
zf check && zig build && zig build test
```

## 6. In-process AI tool

```zig
const tool = zfinal.aichat.ZfTool.init(allocator);
_ = try tool.manifestFromSql(sql);           // SQL stack
_ = try tool.manifestFromZent(zent_schema); // zent stack
_ = try tool.buildAgentSystemPromptZent(zent_schema);
```

## Anti-patterns

- Hand-write CRUD — use `zf crud:sql` or `zf crud:zent`.
- Edit outside `ai-edit-zone` unless updating the generator.
- Mix `zfinal.DB` and `zent` in one transaction.
- Skip `zf check`.
