# AI Quickstart — Build a ZFinal App in 5 Minutes

The fastest path from "I have a domain idea" to a runnable Zig web app.
**Two AI-first data layers** — pick one primary:

| Path | When | Command |
|------|------|---------|
| **A. SQL / DB** | Flat CRUD, existing SQL | `zf crud:sql schema.sql --json` |
| **B. zent** | E-commerce / social / graphs | `zf crud:zent schema.zent --json` |

Both emit `--json` manifests and `ai-edit-zone` markers for agents.

## Path A — SQL (30-second pitch)

```bash
# 1. Write your schema (the only file you truly need)
cat > schema.sql << 'EOF'
CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL, email TEXT NOT NULL);
CREATE TABLE posts  (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INT REFERENCES users(id), title TEXT NOT NULL, body TEXT);
EOF

# 2. One command generates everything
zf crud:sql schema.sql --json | jq '.tables[].files'
# → model/service/handler/routes for users and posts

# 3. Edit only inside ai-edit-zones (the generator marks them)
# 4. Boot
zig build run
```

## Path B — zent (AI-first, same contract)

```bash
cat > schema.zent << 'EOF'
module shop
api_prefix /api/v1
entity User { name: string; handle: string @index }
entity Product {
  seller_id: int
  name: string
  price_cents: int
  stock: int = 0
  list_by: seller_id
}
EOF

zf crud:zent schema.zent --json | jq '.files,.ai_edit_zones'
# → model/persistence/service/handler/routes under src/modules/shop/

# Edit only ai-edit-zones; wire bootstrap printed by zf; then:
zf check && zig build
```

Agent skill: `.claude/skills/zfinal-zent-ai.md` · Demo: `examples/zent-shop/`.

## Why this works

ZFinal's `zf` CLI separates three concerns:

1. **Schema** — `.sql` **or** `.zent`/JSON. The source of truth.
2. **Boilerplate** — generated modules. Always identical for a given schema.
3. **Business logic** — lives in `// ── ai-edit-zone: …` blocks.

`--json` tells an AI exactly which files exist and where to edit.
In-process: `zfinal.aichat.ZfTool.manifestFromSql` / `manifestFromZent`.

## The full 5-minute walkthrough

### Step 0 — Install

```bash
zig build install    # installs `zf` to zig-out/bin/
export PATH="$PWD/zig-out/bin:$PATH"
zf version
```

### Step 1 — Describe your domain in SQL

```sql
-- schema.sql
CREATE TABLE users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    email TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE posts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INT NOT NULL REFERENCES users(id),
    title TEXT NOT NULL,
    body TEXT,
    published BOOLEAN DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

### Step 2 — Run the generator

```bash
zf crud:sql schema.sql --json > manifest.json
```

`manifest.json` is what an AI agent reads. Shape:

```json
{
  "version": "0.9.0",
  "tables": [
    {
      "name": "users",
      "pascal_name": "Users",
      "files": { "model": "users/model.zig", "service": "users/service.zig", ... },
      "ai_edit_zones": [
        { "file": "service.zig", "markers": ["// ai-edit-zone: business rules", ...] }
      ],
      "fields": [
        { "name": "id", "sql_type": "INTEGER", "nullable": true, "primary_key": true },
        ...
      ]
    },
    ...
  ],
  "next_steps": [
    "Review each handler.zig — fill ai-edit-zones for auth, response shaping, custom errors",
    "Add routes via zf route <Table> /<path> (if not auto-generated)",
    "Run: zf check && zig build test",
    "Commit when all checks pass"
  ]
}
```

### Step 3 — Inspect what was generated

```bash
ls src/modules/users/
# handler.zig  model.zig  routes.zig  service.zig

grep -n "ai-edit-zone" src/modules/users/*.zig
# src/modules/users/handler.zig:107:// ── ai-edit-zone: handler hooks ─────
# src/modules/users/model.zig:50:// ── ai-edit-zone: model hooks ─────────
# src/modules/users/service.zig:65:// ── ai-edit-zone: business rules ─────
```

### Step 4 — Add business logic inside the zones

Open `src/modules/users/service.zig`, find the `ai-edit-zone: business rules` block, and add:

```zig
// ── ai-edit-zone: business rules ─────────────
pub fn isUsernameTaken(db: *zfinal.DB, username: []const u8) !bool {
    var result = try db.query("SELECT COUNT(*) FROM users WHERE username = ?");
    defer result.deinit();
    if (try result.next()) {
        const count = try result.currentRow().?.getInt(0);
        return count > 0;
    }
    return false;
}
// ──────────────────────────────────────────────
```

In `src/modules/users/handler.zig`, inside the `handler hooks` zone, add per-route auth:

```zig
// ── ai-edit-zone: handler hooks ──────────────
fn requireAuth(ctx: *zfinal.Context) !void {
    const token = (try ctx.getHeader("Authorization")) orelse return error.Unauthorized;
    // ...validate token...
    _ = token;
}
// ──────────────────────────────────────────────
```

### Step 5 — Verify

```bash
zf check           # AI boundary audit (must pass)
zig build          # compile
zig build test     # run all tests
```

### Step 6 — Run

```bash
zig build run      # or: zig build run-ai-blog-5min
curl http://localhost:8080/health
curl http://localhost:8080/users
```

## Single-file generators

For one-off handlers or middleware outside the CRUD flow, use `zf g`:

```bash
zf g handler HealthCheck    # src/handler/health_check.zig + test stub
zf g service Audit          # src/service/audit.zig
zf g middleware RateLimit   # src/middleware/rate_limit.zig
zf g task CleanupJob        # src/task/cleanup_job.zig
```

Each accepts `--json` for a machine-readable manifest.

## The full playbook for AI agents

- SQL stack: `.claude/skills/zfinal-ai-playbook.md`
- **zent stack: `.claude/skills/zfinal-zent-ai.md`**

TL;DR:

1. Read `CLAUDE.md` and `AGENTS.md`.
2. Pick primary: `zf crud:sql … --json` **or** `zf crud:zent … --json`.
3. Edit **only** inside `ai-edit-zone` markers.
4. Run `zf check && zig build test`.
5. Commit and ship.

## Why we built it this way

Three reasons:

- **Boilerplate is the enemy of velocity.** Hand-writing CRUD is 80% of typical web tasks. `zf` collapses it to one command.
- **AI needs boundaries.** Without `ai-edit-zone` markers, an AI overwrites generated code or invents its own patterns, drifting from the framework. The markers tell it exactly where it can act.
- **Machines need machine output.** `--json` lets an agent parse what was created and decide what to do next, instead of grep-ing the working tree.

## See also

- `examples/ai-blog-5min/` — runnable SQL 5-minute walkthrough
- `examples/zent-shop/` — zent primary (e-commerce + social)
- `.claude/skills/zfinal-ai-playbook.md` — SQL AI script
- `.claude/skills/zfinal-zent-ai.md` — zent AI script
- `.claude/skills/zfinal-health.md` — CI / health checks
- `doc/zent.md` — zent as DB alternative / primary
- `doc/zf_cli.md` — full `zf` reference
- `doc/getting_started.md` — framework basics
