---
name: zfinal-ai-playbook
description: Use when developing a ZFinal web app and you need to know the exact sequence of `zf` commands and file edits. Triggers on "new feature in zfinal", "add a model/handler", "regenerate from SQL", or any task that combines `zf` CLI with hand-written business logic.
---

# ZFinal AI Playbook — Standard Script

The complete sequence an AI follows to add a feature in a ZFinal app. Use this when the user asks to add a new entity, endpoint, or CRUD capability.

## 1. Read the situation

Before invoking any `zf` command:

- Read `CLAUDE.md` (Health Stack, development notes) and `AGENTS.md` (gen/edit boundaries).
- Confirm the project is on `main` or a feature branch.
- Identify the SQL schema source: a file, an existing DB, or a DDL sketch in the user's message.

## 2. Generate from SQL (preferred)

```bash
# Parse schema and emit model/service/handler/routes + tests
zf crud:sql schema.sql [project_name] [--force] [--json]
```

Always use `--json` to receive a machine-readable manifest. Parse it to learn:

- `tables[].files.model` / `.service` / `.handler` / `.routes`
- `tables[].ai_edit_zones` (where to add business logic)
- `tables[].fields` (column types and nullability)
- `next_steps[]` (what to do after generation)

## 3. Edit inside the AI edit zones

Generated files contain markers like:

```zig
// ── ai-edit-zone: business rules ─────────────
```

Inside these zones, add the requested logic. Examples:

- `service.zig` — cross-table validation, computed fields, audit hooks
- `handler.zig` — per-route auth checks, response shaping, custom error codes
- `model.zig` — model-level hooks (rare; usually stays empty)

Keep edits small. Promote complex logic to a new `business.zig` rather than nesting inside generated files.

## 4. Add routes (if not auto-generated)

```bash
zf g handler <Entity>        # single-file handler (non-CRUD)
zf g service <Entity>        # service skeleton
zf g middleware <Name>       # interceptor
zf g task <Name>             # scheduled task
```

Each accepts `--json` to emit a manifest with the output path and next steps.

## 5. Verify

```bash
zf check                     # AI boundary audit (must pass)
zig build                    # compilation
zig build test               # unit + integration tests
```

If any step fails, fix inside the `ai-edit-zone` — never touch generated boilerplate outside the zones.

## 6. Commit and ship

- Stage only intentional files. Generated files committed alongside your edits.
- Commit message: `feat: <what>` or `fix: <what>`.
- Tag with `zf version` or by editing `CHANGELOG.md` then `git tag v0.X.Y`.
- Push to `origin` and create a GitHub release.

## Anti-patterns

- **Don't** hand-write `model.zig` / `handler.zig` from scratch. Use `zf crud:sql` or `zf g`.
- **Don't** edit outside `ai-edit-zone` markers unless you also update the generator template.
- **Don't** run `zig fmt` on `.gen.zig` files — the generator emits pre-formatted code.
- **Don't** skip `zf check`. It catches boundary violations before commit.
