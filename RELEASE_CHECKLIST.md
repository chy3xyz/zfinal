# Release Checklist

> **Version-agnostic.** The release version is single-sourced in
> `src/version.zig` (`semver`, mirrored in `build.zig.zon`); the supported
> Zig toolchain is single-sourced in the repo-root `.zig-version` file.
> Never hardcode either value in this checklist.
>
> `zf release-check` (default `--strict`) is the mechanical source of truth
> for the pre-tag gate — version parity, a `## [semver]` CHANGELOG section,
> tag availability, and a clean working tree. See
> [doc/release_and_quality_gates.md](doc/release_and_quality_gates.md).

## Pre-release gate

- [ ] `zf release-check` passes (version ≡ `build.zig.zon`, CHANGELOG has the
      matching `## [semver]` section, `v$semver` tag is free or points at HEAD,
      working tree clean)
- [ ] `zig build gate` (or `bash scripts/quality_gate.sh full`) passes
- [ ] `zig build test` — **all green** (16 skipped without live env)
- [ ] `zig build test-zf` — codegen regression suites pass
- [ ] `zig build` — framework + all examples compile
- [ ] `zig fmt --check src/ test/ tools/ benchmark/ examples/ build.zig`
- [ ] Memory leak check: debug allocator reports 0 leaks
- [ ] `zig build -Doptimize=ReleaseSafe` + production binary smoke test

## Documentation

- [ ] Install pins in `README.md` / `README_CN.md` point at the new tag
- [ ] `CHANGELOG.md` — new `## [x.y.z]` section added, versions strictly descending
- [ ] `PRODUCTION_AUDIT.md` — deployment contract still accurate
- [ ] `SECURITY.md` — supported-versions table updated
- [ ] `doc/` — 47 documentation pages consistent; version/toolchain claims refer
      to `src/version.zig` / `.zig-version` rather than hardcoded values

## Examples

- [ ] Every `examples/*` project compiles under `zig build`
- [ ] Production example runs: `zig build run-production`

## Tag + release

- [ ] Commit all changes
- [ ] Push to main
- [ ] Create annotated tag `v<semver from src/version.zig>`
- [ ] `git push origin <tag>`
- [ ] Create the GitHub release for the tag
