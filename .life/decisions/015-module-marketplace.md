# ADR-015: Module marketplace — local catalog first

**Status**: Accepted  
**Date**: 2026-07-31

## Context

Reusable examples/plugins (zent-shop, smart-routing, ports-l2/l3) exist under
`examples/` and `src/plugin/`, but agents discover them only by browsing the
tree. A full remote “module market” (registry, signed packages, `zf market
install`) is valuable later — after release/quality gates are productized
(ADR-014).

## Decision

1. **Phase 1 (now)**: local catalog `marketplace/catalog.json` +
   `zf market list|search|info [--json]`. Discoverability only; copy/wire
   modules manually (or via existing `zf` generators).
2. **Out of scope for phase 1**: remote index, download, dependency
   resolution, signing, auto `build.zig.zon` edits.
3. **Phase 2+** (future ADR): remote registry + install; must require
   `zf gate` / CI green and catalog schema versioning.
4. Document in [`doc/module_marketplace.md`](../../doc/module_marketplace.md).

## Consequences

- Agents can `zf market search zent --json` without inventing paths.
- Catalog entries are curated; not every file under `examples/` is listed.
- Installing from market remains a human/AI follow-up using paths in the
  catalog — no silent network fetch.
