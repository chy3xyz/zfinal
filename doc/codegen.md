# ZFinal Code Generator (`zf`)

## Quick Commands

```bash
zf new myproject            # Create new project
zf new myproject --clean    # No demo code
zf crud:sql schema.sql       # Generate from SQL file
zf crud:dsn postgresql://... # Generate from live DB
zf g model User             # Generate model stub
zf g handler User           # Generate handler stub
zf g port store|cache|bus   # L2/L3 ports + adapter stubs (see progressive_architecture.md)
zf check                    # Audit AI compliance
```

## Ports codegen (L2/L3)

```bash
zf g port store --json   # → src/ports/store.zig + memory_store / pg_store adapters
zf g port cache --json   # → src/ports/cache.zig + memory_cache / redis_cache
zf g port bus --json     # → src/ports/bus.zig + Memory/Nats/RobustMQ re-exports (doc/bus.md)
```

Edit only `// ── ai-edit-zone` blocks; wire adapters in `main.zig` as in
[progressive_architecture.md](progressive_architecture.md).
Runnable reference: `examples/ports-l2` (`zig build run-ports-l2`).

## Regeneration / ai-edit-zone merge

When a generated file already exists:

1. Matching `ai-edit-zone: <name>` blocks are **preserved** from the old file into the new template.
2. If no matching zones → write `<path>.gen.new` (review with `diff`).
3. `--force` overwrites the whole file (skips merge).

```bash
zf crud:sql schema.sql        # merges zones when present
zf check --prod               # reference: examples/production
zf check --prod --root src    # your app root (or examples/ports-l2)
```

## gen + ext Pattern

`zf` separates generated code from handwritten code:

```
src/modules/system/user/
├── model.gen.zig      ← AI regenerates (never edit)
├── ext/model.zig      ← Your custom code (write once)
├── handler.gen.zig    ← AI regenerates
├── ext/handler.zig    ← Your custom code
├── service.gen.zig    ← AI regenerates
├── ext/service.zig    ← Your custom code
└── routes.zig         ← AI regenerates (route table)
```

## Generated Project Structure

```
myproject/
├── build.zig
├── build.zig.zon
├── CLAUDE.md              # AI guard rails
├── src/
│   ├── main.zig           # Entry point
│   ├── App.zig            # DB, pool, routes
│   ├── config.zig         # Server/DB config
│   ├── deps.zig           # Pool, tokenMgr, rateLimiter
│   ├── routes.zig         # Route table
│   ├── modules/
│   │   ├── manifest.gen.zig  # Auto-aggregated
│   │   └── {module}/
│   │       ├── model.gen.zig
│   │       ├── ext/model.zig
│   │       ├── service.gen.zig
│   │       ├── ext/service.zig
│   │       ├── handler.gen.zig
│   │       ├── ext/handler.zig
│   │       └── routes.zig
│   ├── common/
│   │   ├── constants.zig
│   │   └── errors.zig
│   └── validator/validate.zig
├── test/
│   ├── gen/{name}_test.gen.zig
│   └── integration/{name}_int_test.gen.zig
├── .claude/skills/zfinal-app.md
├── .opencode/instructions.md
└── .cursor/rules/zfinal.mdc
```

## Generated Security Features

| Feature | Implementation |
|---------|---------------|
| CSRF protection | `csrfGuard(ctx)` on POST/PUT/PATCH/DELETE |
| Rate limiting | `RateLimitHandler` on list endpoints |
| Sensitive data | `safeFields` excludes password/token/hash |
| Input validation | `validate()` checks required/email/length |
| SQL injection | All DB via parameterized `execParams` |
| Connection pool | Per-request `acquire`/`release` cycle |

## Generated Handler Example

```zig
pub fn create(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);        // CSRF check
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    // Parse fields from request...
    const data = Model.Data{ ... };
    const instance = service.create(db, data) catch |e| {
        if (e == error.ValidationError) return failHttp(ctx, error.UnprocessableEntity, "validation");
        return e;
    };
    try ctx.renderJson(.{ .ok = true, .id = instance.id });
}
```

## Module Path Convention

Table names map to module paths via underscore splitting:
- `sys_user` → `modules/sys/user/`
- `system_dict_data` → `modules/system/dict/data/`
- `blog_post` → `modules/blog/post/`

## DB Introspection

```bash
# From SQL file (DDL → SQLite → PRAGMA table_info)
zf crud:sql schema.sql myproject

# From PostgreSQL (information_schema)
zf crud:dsn postgresql://user:pass@host/db

# From MySQL (SHOW TABLES/COLUMNS)
zf crud:dsn mysql://user:pass@host/db
```

## Declarative List Filters (ADR-017) — `-- @filter` column annotations

Annotate columns in the source schema to generate a typed `Filters` struct and
a `Model.Query`-based `service.list(db, f, page, size)`:

```sql
CREATE TABLE posts (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  title   TEXT,
  status  TEXT,          -- @filter @in_list
  views   INTEGER,       -- @filter @sortable
  content TEXT,          -- @search
  secret  TEXT           /* @hidden */
);
```

| Tag | Effect |
|-----|--------|
| `@filter` | Add an `eq` filter to `service.Filters` (`?i64` / `?f64` / `?bool` / `?[]const u8` by column type) |
| `@search` | Add the column to the generated `LIKE` search (`f.q`) |
| `@sortable` | Whitelist the column for the `sort` query param (matched against constants only) |
| `@hidden` | Exclude the column from list output (like existing sensitive-field exclusions) |
| `@in_list` | No-op (columns are in the list by default) |

When any annotation is present, the generated handler uses the declarative
pipeline instead of the legacy `q`-only search:

```zig
pub fn list(ctx: *zfinal.Context) !void {
    try rateLimiter.handle(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    var f: service.Filters = .{};
    try ctx.bindQuery(&f);
    const page = try ctx.getParaToLongDefault("page", 1);
    const size = try ctx.getParaToLongDefault("size", 20);
    try ctx.renderPage(try service.list(db, f, @intCast(page), @intCast(size), ctx.allocator), ctx.allocator);
}
```

Generated `Filters` also carries `q` (search), `sort`, and `order`
(`?enum { asc, desc }`) when applicable. Column names in the generated query
are compile-time validated by `Model.Query` — typos fail at build time.

**Requirement:** annotated-mode generated code uses `Model.Query`,
`Context.bindQuery`, and `Context.renderPage` (ADR-017), so the project must
depend on a zfinal release that includes them (≥ the release after v0.20.15).

### Validation rules (`-- @required` / `-- @min` / `-- @max` / `-- @email` / `-- @unique`)

Column annotations also drive the generated `validate()` and a uniqueness check:

```sql
CREATE TABLE products (
  id    INTEGER PRIMARY KEY AUTOINCREMENT,
  sku   TEXT NOT NULL,        -- @required @unique
  price REAL NOT NULL,        -- @required @min(0) @max(10000)
  email TEXT                  -- @email
);
```

| Tag | Generated check |
|-----|-----------------|
| `@required` | text → non-empty (`data.x.len == 0` → error); optional → non-null |
| `@min(N)` / `@max(N)` | numeric bounds → `error.ValidationError` |
| `@email` | basic format (`@` presence) → `error.InvalidEmail` |
| `@unique` | `service.validateUnique(db, data)` queries `WHERE col = ?` → `error.DuplicateEntry`; called from generated `create`/`update` |

`validateUnique` is always emitted (no-op when no `@unique` columns), so
generated services stay consistent.

### API view projection (`-- @hidden` → `View` + `toView`)

A table with any `-- @hidden` column also generates a `View` struct (all
non-hidden columns) and `Instance.toView()`; the generated `show` handler
returns `item.toView()` so hidden columns never leave the API:

```zig
pub const View = struct {
    id:    ?i64,
    name:  []const u8,
    email: ?[]const u8,   // `secret` excluded — marked -- @hidden
};

pub fn toView(self: *const UsersModel.Instance) View { ... }
```

`View` fields borrow the instance's strings (valid for the handler scope).
Tables without `@hidden` columns skip the projection entirely.

### Generated schema file (`schema.gen.sql`) + annotation-derived indexes

Each module now ships a `schema.gen.sql`: the original `CREATE TABLE` verbatim
plus `CREATE INDEX` statements derived from annotations — `@unique` → unique
index, `@filter` / `@sortable` → plain index (primary keys skipped):

```sql
-- src/modules/posts/schema.gen.sql (regenerate: zf crud:sql)
CREATE TABLE posts ( ... );   -- original DDL preserved

-- Indexes derived from annotations (@filter/@sortable/@unique, ADR-017)
CREATE INDEX IF NOT EXISTS idx_posts_status ON posts(status);
CREATE INDEX IF NOT EXISTS idx_posts_views ON posts(views);
CREATE UNIQUE INDEX IF NOT EXISTS idx_posts_sku_u ON posts(sku);
```

This is what makes the performance guidance actionable: **the filters/sort you
declare are the indexes you get** — apply `schema.gen.sql` to your DB (or
`zf migrate`) and the filtered list / `validateUnique` paths go index-driven.
