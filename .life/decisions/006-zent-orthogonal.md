# ADR-006: Orthogonal zent integration (no core dependency)

**Status**: Superseded by [ADR-007](007-zent-peer-data-layer.md)  
**Date**: 2026-07-20

## Context

E-commerce and social apps need dense relationships (orders graph, follow graph).
zent provides ent-style schema-as-code; ZFinal already has `zf crud:sql` + `db.Model`.
zigmodu integrates zent as an optional path dependency in examples, not in the core library.

## Decision (historical)

1. Do **not** add zent to `zfinal/build.zig.zon` core dependencies.
2. Document selection rules in `doc/zent.md`.
3. Ship `examples/zent-shop` with path dep on sibling `../zent` (or remote tag).
4. Forbid mixing `zent.Driver` and `zfinal.DB` in one transaction.

## Consequences

- Apps that need graphs opt into zent; simple CRUD keeps using `zf`.
- CI for core `zig build test` stays zero-zent.
- Developers must clone zent next to zfinal for the demo.

Superseded: zent is now a **peer data layer** (`zfinal.zent` alongside `zfinal.DB`), default-on via `-Denable-zent`.
