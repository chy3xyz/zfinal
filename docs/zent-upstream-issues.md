# zent: Zig 0.17 compat + API hardening findings (from a 9-entity production schema)

Integration report from [zfinal](https://github.com/chy3xyz/zfinal) v0.22.x × zent v0.28.0
(a 9-entity e-commerce + social schema: edges, data_scope, QueryEdge, TxClient, Enum fields).
All findings verified against `v0.28.0` source; numbered by impact.

> **v0.29.3 status update** (2026-08-07): **#1 (WhereIn 2-arg append) is FIXED**
> upstream (v0.29.3) — zfinal removed its `sql.In` workaround and restored
> `WhereIn` (feed/recommend), all tests green. **#2 (From-edge FK dedup) is NOT
> yet fixed** — zfinal keeps the `isRefFk` skip.

## 1. `WhereIn()` still doesn't compile on Zig 0.17 (`append` 2-arg) — since v0.27

`codegen/query.zig` `WhereIn()`:
```zig
try self.or_in_chunks.append(self.allocator, chunks);   // ~L359
try self.predicates.append(self.allocator, sql.OrIn(column, chunks)); // ~L360
```
Zig 0.17 `ArrayList.append` takes 1 arg (allocator bound at init). Any call to
`WhereIn` fails to compile (`member function expected 1 argument(s), found 2`).
Workaround: `q.Where(.{sql.In(col, values)})` — same predicate, but the public
`WhereIn` API is unusable on the pinned Zig.

**Fix**: `append(chunks)` / `append(sql.OrIn(...))` (drop the allocator arg).

## 2. `addEdgeFields` From-edge FK column duplication (asymmetric with To-edge)

`codegen/graph.zig` "Own From edges generate FK columns in this table":
```zig
for (info.edges) |e| {
    if (e.kind == .from and (e.relation == .m2o or e.relation == .o2o)) {
        const fk_col_name = e.name ++ "_id";
        fields = fields ++ &[_]FieldInfo{ ... };   // no exists check
```
The **To**-edge branch (~L387) checks `var exists = false; for (fields) ...` and
skips existing columns; the **From** branch always appends. A schema that writes
the FK column explicitly **and** declares `edge.From("seller", User).Field("seller_id")`
ends up with a duplicate column (`duplicate struct field 'seller_idEQ'` in predicates).
The generator (zfinal) must skip emitting the FK field to work around this.

**Fix**: mirror the To-edge `exists` check in the From branch (match
`e.field_name` against existing fields).

## 3. `QueryEdge` result order is not guaranteed to match `parent_ids`

`QueryEdge(edge_name, parent_ids)` returns a flat `ArrayList(Target)`; the order
is not documented as matching `parent_ids`, so callers must do an O(n·m) linear
lookup to map parents → targets (zfinal's feed demo does this).

**Fix**: document the ordering, or return per-parent batches.

## 4. Builder API naming inconsistency

`Update().Save()`, `Delete().Exec()`, `BulkDelete().Exec()`, `BulkUpdate().Save()`
— the "commit" method name differs per builder, which is a common source of
compile-time confusion. A short matrix in the README (or aliasing `Exec`/`Save`)
would help.

## 5. `data_scope` empty-context semantics are undocumented

With `policy = data_scope.Policy`: no `PrivacyContext` at all → **deny**
(`PrivacyDenied`); empty context (`.{}`, extra=null) → **allow-all** (filter
returns null). Both are load-bearing for integration code but only discoverable
by reading `privacy/data_scope.zig`. zfinal's generator had to encode this in
comments.

**Fix**: document the "no context = deny / empty ctx = no restriction" contract
in `privacy/data_scope.zig` or README.

## 6. Missing usage examples

- `shard` (hash routing) — implementation exists, no worked example.
- `crud.CrudService.on_event` → outbox/bus wiring — event source exists, no
  end-to-end example.
- `@sensitive` → `toMaskedJson` — field flag exists, no response-shaping example.

---

All reproducible with `zig build test-zent-shop` in zfinal (zfinal pins zent v0.28.0).
Happy to turn any of these into a PR.
