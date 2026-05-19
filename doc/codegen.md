# ZFinal Code Generator (`zf`)

## Quick Commands

```bash
zf new myproject            # Create new project
zf new myproject --clean    # No demo code
zf crud:sql schema.sql       # Generate from SQL file
zf crud:dsn postgresql://... # Generate from live DB
zf g model User             # Generate model stub
zf g handler User           # Generate handler stub
zf check                    # Audit AI compliance
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
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    // Parse fields from request...
    const data = Model.Data{ ... };
    const instance = service.create(db, data) catch |e| {
        if (e == error.ValidationError) return err(ctx, .unprocessable, "Invalid data", 42201);
        return err(ctx, .internal, "Server error", 50001);
    };
    try ctx.renderJson(.{ .data = instance });
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
