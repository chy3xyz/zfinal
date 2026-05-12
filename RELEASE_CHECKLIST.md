# Release Checklist

## Current Release: v0.3.0 (2026-05-12)

### Code Quality
- [x] All tests pass: `zig build test` (88 passed, 2 skipped, 0 failed)
- [x] All examples compile: `zig build` (11 examples + benchmark + CLI tool)
- [x] Production audit complete: `PRODUCTION_AUDIT.md` (~94% readiness)
- [x] Memory leak check: debug allocator with 0 reported leaks
- [x] Security audit: all critical/high issues resolved (see audit report)

### Documentation
- [x] `README.md` — full project overview, features, examples, roadmap
- [x] `PRODUCTION_AUDIT.md` — complete security and quality audit
- [x] `SECURITY.md` — security policy, built-in features, best practices
- [x] `CHANGELOG.md` — detailed changelog with all versions
- [x] `CONTRIBUTING.md` — contribution guidelines
- [x] `INSTALL.md` — installation guide
- [x] `doc/` — 12 documentation pages (getting started, core concepts, database, advanced, kits, CLI, tutorials)

### Examples
- [x] `hello-world` — minimal demo
- [x] `blog` / `blog-single` — blog with SQLite
- [x] `htmx` — HTMX interactive app
- [x] `websocket` — WebSocket echo server
- [x] `auth` — authentication example
- [x] `captcha` — CAPTCHA demo
- [x] `edge` — edge computing
- [x] `pocketbase` — PocketBase-like example
- [x] `generator` — code generation
- [x] `production` — production-grade example

### Release Steps
- [x] Build passes: `zig build`
- [x] Tests pass: `zig build test`
- [x] Commit all changes
- [x] Push to main
- [x] Create tag: `v0.3.0`
- [x] Create GitHub release: `gh release create v0.3.0`

---

## Next Release: v0.4.0

### Planned
- [ ] Template v2 (advanced filters, macros)
- [ ] Admin dashboard (metrics, health, errors)
- [ ] Docker deployment example
- [ ] API reference docs (`zig build docs`)
- [ ] WebSocket frame fragmentation
- [ ] Response compression (gzip)

### Pre-release
- [ ] `zig build test` — all tests pass
- [ ] `zig build` — all examples compile
- [ ] Cross-platform build verified (macOS x86_64, Linux x86_64)
- [ ] `CHANGELOG.md` updated
- [ ] Version bumped in build.zig and docs
- [ ] Tag and release created
