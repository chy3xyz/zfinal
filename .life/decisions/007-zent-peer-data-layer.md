# ADR-007: zent as alternative (and optional primary) to DB/Model

**Status**: Accepted  
**Date**: 2026-07-20

## Context

ADR-006 kept zent outside the core package. Product feedback asked for zent at the
**same level** as `zfinal.DB` / `Model`, and for graph-heavy products to use zent as
the **primary** persistence stack — not a secondary bolt-on.

## Decision

1. Add **zent** (`v0.12.0+`) to root `build.zig.zon`.
2. Export **`zfinal.zent`** next to **`zfinal.DB`** / **`Model`** (`src/data/zent_layer.zig`).
3. Gate with **`-Denable-zent`** (default **true**).
4. Treat the two stacks as **mutually alternative primaries**:
   - App or module picks **A (`DB`)** or **B (`zent`)** as main ORM.
   - E-commerce / social / dense RBAC → prefer **zent as primary**.
   - Flat CRUD / SQL-first / `zf crud:sql` → prefer **`DB` as primary**.
5. **Never mix** `zent.Driver` and `zfinal.DB` in one transaction.
6. Document selection in `doc/zent.md`; demo full-app zent-primary in `examples/zent-shop`.
7. Ship **`zf crud:zent`** (`tools/zf/zent_codegen.zig`) as the generator parallel to `zf crud:sql`.

## Consequences

- Discoverability: `import zfinal` shows both choices equally.
- Graph products can ship with **only** zent for domain data (HTTP/plugins still ZFinal).
- Thin trees: `-Denable-zent=false`.
- Mixed apps allowed **per module**, with Queue for cross-domain side effects.
