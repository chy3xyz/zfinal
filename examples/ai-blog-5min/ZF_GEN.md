# ai-blog-5min — AI Speedrun

A runnable 5-minute walkthrough of the ZFinal AI-driven development flow.

## What this is

A minimal scaffold that pairs with the `zf crud:sql` generator. The
`schema.sql` is the source of truth; running one `zf` command produces
the full model/service/handler/routes tree, and the developer (or AI)
only needs to edit inside the `// ── ai-edit-zone: …` markers.

## Steps

### 1. Read the schema

```bash
cat schema.sql
```

Two tables: `users` and `posts`. `posts.user_id` references `users.id`.

### 2. Generate CRUD

```bash
zf crud:sql schema.sql --json
```

The generator emits a JSON manifest on stdout plus:

- `src/modules/users/{model,service,handler,routes}.zig`
- `src/modules/posts/{model,service,handler,routes}.zig`
- `src/modules/manifest.gen.zig` (route aggregator)
- `test/gen/{user,post}_test.gen.zig`
- `test/integration/{user,post}_int_test.gen.zig`

### 3. Edit inside the ai-edit-zones

Each generated `service.zig` and `handler.zig` has a marker block. Add
your business logic between the dashed lines. Example for `posts.service.zig`:

```zig
// ── ai-edit-zone: business rules ─────────────
pub fn isAuthor(db: *zfinal.DB, post_id: i64, user_id: i64) !bool {
    const post = try PostsModel.findById(db, post_id, db.allocator) orelse return false;
    defer post.deinit(db.allocator);
    return post.data.user_id == user_id;
}
// ──────────────────────────────────────────────
```

### 4. Run

```bash
zig build run-ai-blog-5min
```

### 5. Try it

```bash
curl http://localhost:8080/health
# → {"example":"ai-blog-5min","status":"ok"}

# After zf crud:sql, also available:
curl http://localhost:8080/users
curl -X POST http://localhost:8080/users -d 'username=alice&email=a@x.com'
```

## Anti-patterns

- **Don't** hand-write `model.zig` / `handler.zig` boilerplate. Use `zf crud:sql`.
- **Don't** edit generated code outside the `ai-edit-zone` markers.
- **Don't** commit `zfinal_migration.zig` (gitignored).
- **Don't** run `zig fmt` on `.gen.zig` files.

## See also

- `.claude/skills/zfinal-ai-playbook.md` — the full AI playbook
- `doc/ai-quickstart.md` — the human-readable quick start
- `tools/zf/main.zig` — CLI source
- `tools/zf/codegen.zig` — code generator source
