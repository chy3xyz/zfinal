# ADR-017: Declarative list query + DTO binding

**Status**: Accepted  
**Date**: 2026-07-22

## Context

Generated list endpoints (`tools/zf/codegen.zig:758`) hand-write the whole
pipeline per entity: parse `page`/`size`/`q` via repeated `ctx.getPara*`,
build a `q`-only `OR LIKE` WHERE string, maintain `SqlParam[]` arrays by hand
(the #1 source of binding-mismatch bugs), and assemble the paged JSON shape
ad-hoc. Adding filters (status, category, date range, sort) means more
hand-written SQL per endpoint. DTOs are plain structs with manual parse +
manual validation.

## Decision

Add framework-level conveniences (no new deps):

1. **`Model.Query` (A)** — a fluent, comptime-validated query builder nested in
   `ModelWithPK` (`src/db/model.zig`):
   - `eq/textEq/like/gt/gte/lt/lte(comptime col, ?value)` — column names are
     compile-time validated against the model's field list (typos and
     injection-shaped names fail at compile time).
   - `orderBy(comptime col, .asc|.desc)` — column whitelist at comptime.
   - `page(page, size)` / `list(allocator)` / `count()` / `paginate(page, size, allocator)`.
   - WHERE fragments + `SqlParam[]` built together → binding mismatch impossible.
2. **`Context.bindQuery(allocator, *Filters)` (B)** — reflect over a struct's
   fields and bind query-string params by field name; supported types:
   `?i64`, `?i32`, `?f64`, `?bool`, `?[]const u8`, and optionals of enums
   (`?enum { asc, desc }`). Missing params keep the struct's defaults; bad
   values return a 400 with the field name. Pure core is a file-scope helper
   so it is unit-testable without an HTTP request.
3. **`Context.renderPage(page, allocator)` (C)** — serializes
   `{data, total, page, size}` from a `Page(T)`-shaped value, then frees the
   items (calling `deinit(allocator)` when the item type has it) and the list.
   One call replaces the ~4-line render + free dance in every list handler.
4. **Generator integration (D)** — deferred to a follow-up ADR: manifest
   markers (`@filter/@search/@sortable/@in_list`) so `zf crud` emits
   `Filters` + `service.list(db, f, page, size)` automatically. A+B+C ship
   first; D consumes them.

Target shape for business code (after D):

```zig
pub fn list(ctx: *zfinal.Context) !void {
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    var f: service.Filters = .{};
    try ctx.bindQuery(&f);
    const page = try ctx.getParaToLongDefault("page", 1);
    var q = service.Model.Query.init(db, ctx.allocator);
    defer q.deinit();
    try q.eq("status", f.status).likeAll(&.{"name", "email"}, f.q);
    try q.orderBy(f.sort, f.order);
    try ctx.renderPage(try q.paginate(@intCast(page), 20, ctx.allocator), ctx.allocator);
}
```

## Consequences

- Business code stops hand-writing WHERE + params; column typos become
  compile errors instead of runtime SQL errors.
- All paged responses share one JSON shape and one ownership path.
- Query building is still explicit (no hidden global state); each `Query` owns
  its buffers and must be `deinit`ed.
- D is required for new projects to benefit automatically; until then the new
  API is opt-in for hand-written services.
