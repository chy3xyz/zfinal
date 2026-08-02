# ADR-016: Module marketplace phase 2 — remote index + install

**Status**: Accepted  
**Date**: 2026-07-22  
**Supersedes**: extends [ADR-015](015-module-marketplace.md) (phase 1 local catalog)

## Context

Phase 1 (ADR-015) delivered `marketplace/catalog.json` + `zf market list|search|info`
— discoverability only. Agents find modules but must still copy/wire them by hand.
ADR-015 deliberately deferred remote install until quality gates were productized
(ADR-014). Gates are now stable; this ADR ships the remote layer.

## Decision

Ship **Phase 2 = remote index + artifact install**, reusing machinery the `zf` CLI
already has (`std.http.Client` in `cmd_bench.zig`, `zig fetch --save` pattern in
`cmd_scaffold.zig`, and `std.tar.extract` from the stdlib).

1. **Registry = the repo's `marketplace/catalog.json` served via GitHub raw.**
   Default URL: `https://raw.githubusercontent.com/chy3xyz/zfinal/main/marketplace/catalog.json`.
   No dedicated server. `--registry URL` overrides; local `--catalog PATH` always wins.
2. **`zf market update`** fetches the registry over HTTPS and caches it to
   `~/.cache/zf/marketplace-catalog.json`. `list|search|info` prefer the cache,
   falling back to the repo-local catalog when the cache is missing. Offline /
   non-200 → clear error + fallback.
3. **Catalog schema v2**: entries gain a `"url"` field (artifact tarball URL).
   `path` keeps meaning "subdirectory of `path` inside the tarball".
4. **`zf market install <id>`**:
   - resolves the entry (cache → local catalog → `--catalog`);
   - downloads `url` with `std.http.Client` to a temp file;
   - extracts the `path` subdir with `std.tar.extract`. GitHub archive tarballs
     carry a top-level prefix (e.g. `zfinal-v0.20.3/`), so `path` is matched by
     suffix against each tar entry's path; files outside the matched prefix are
     skipped;
   - places it: `kind: plugin` → `src/plugin/`, `kind: example|module` →
     `vendor/marketplace/<id>/` (or `--dir DIR`);
   - `--dry-run` prints the plan and touches nothing; `--verify` runs
     `zig build` + `zf check` after install.
5. **Out of scope for phase 2**: signed packages, `build.zig.zon` auto-merge for
   package-type modules, CI install-regression hooks, per-module publishing
   repos. These become phase 2c only after a real publisher exists.

## Consequences

- Agents can `zf market update && zf market install example/zent-shop --dry-run`
  without inventing URLs or tarball layouts.
- Install remains explicit and local: network fetch only happens on
  `update`/`install`, never during `list/search/info` when a cache exists.
- HTTPS + curated catalog is the trust model for now; signing (2c) only when
  third-party publishing needs it.
- Every entry without `url` still lists/searches fine but `install` reports a
  clear "no remote artifact" error.
