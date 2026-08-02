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
