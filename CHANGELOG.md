# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.12.7] - 2026-06-13

### Fixed (P0)
- **Segfault at 0xaaaaaaaaaaaaaaaa in conn.ping()**: `DB.init()` now returns `*DB` (heap-allocated) instead of `DB` (value). The Driver union (MySQLDB/PostgresDB/SQLiteDB) has platform-specific internal state that doesn't survive struct copy on aarch64-macos with Zig 0.17's debug allocator (0xaa fill pattern → freed memory read). ConnectionPool no longer copies DB structs — it stores the heap pointer directly. Added `DB.destroy()` for convenient deinit+free.

## [0.12.6] - 2026-06-13

### Added
- **`zf ai` HTTP implementation**: real POST to `https://api.openai.com/v1/chat/completions` via `std.http.Client.fetch`. Reads `OPENAI_API_KEY` env (via libc `getenv`), sends proper JSON body with project context, captures response into fixed buffer, parses `content` field, prints assistant message. Ready for use with any OpenAI API key.

## [0.12.5] - 2026-06-13

### Added
- **`zf ai`**: AI assistant with ZFinal context loader. `zf ai <prompt...> [--provider openai|anthropic] [--model <name>]` automatically loads AGENTS.md + .claude/skills/ listing into the prompt context. Builds proper OpenAI-compatible JSON request body. (HTTP fetch to LLM endpoint deferred — user runs the printed curl/API call manually, or wires in `std.http.Client` POST with bearer auth.)

## [0.12.4] - 2026-06-13

### Added
- **`zf bench`**: HTTP load testing tool. `zf bench <url> [--count N] [--concurrency C]` fires N requests with C workers, reports RPS, p50/p95/p99 latency, min/max, error rate, status code distribution. Uses `std.http.Client.fetch` + `std.Io.Timestamp` for per-request timing. Verified against localhost: 5 requests in 13ms, p50=1.6ms.

## [0.12.3] - 2026-06-13

### Added
- **`zf fixture`**: generate fake test data. `zf fixture <table> [--count N] [--run] [--format sql|json]`. Infers schema from `sqlite_master`, generates realistic data via name-based generators (name→User N, email→userN@…, status→active/pending/…, created_at→DATETIME('now'), price→10.50) + type-based fallbacks (INT/REAL/TEXT/BLOB). Auto-skips AUTOINCREMENT PK. Verified inserting 5 rows into a `users` table.

## [0.12.2] - 2026-06-13

### Added
- **`zf seed`**: database seeding tool — companion to `zf migrate`. Subcommands: `new` (create timestamped seed file), `run`/`up` (apply pending), `list` (show ✓/○), `reset` (clear tracking). Idempotent — re-running skips already-applied seeds. Templates use `INSERT OR IGNORE` for safety. Tracking via `_zfinal_seeds` table.

## [0.12.1] - 2026-06-13

### Added
- **`zf migrate` full implementation**: `zf migrate up` applies pending migrations in order, `zf migrate down` reverts most recent, `zf migrate status` shows applied (✓) and pending (○). Migration files use Flyway-style `-- Up` / `-- Down` sections; only the Up section runs on apply (Down stays untouched for rollback). Tracking via `_zfinal_migrations` table (version, filename, applied_at, checksum).

## [0.12.0] - 2026-06-13

### Added
- **`zf new` bundles AI skills**: when running from the zfinal repo root, `zf new <project>` copies all 7 framework AI skills (onboarding, ai-playbook, framework, health, evolution, debug, evolve) plus zfinal-app.md summary into the new project's `.claude/skills/`. AI agents working on the new project have full context from day one.
- **`zf new` generates GitHub Actions workflow**: new projects get `.github/workflows/test.yml` that runs `zig build` + `zig build test` + `zf check` + `zf check --heal` on every push/PR. Catches regressions before merge.
- **Source-path discovery**: `zf new` walks up to 5 parent directories to find the framework skills source. Works when zf is run from the zfinal repo root.

## [0.11.1] - 2026-06-13

## [0.10.9] - 2026-06-16

### Added
- **MySQL binlog replication API**: `DB.binlogOpen/BinlogFetch/binlogClose` wrap libmysqlclient's `mysql_binlog_open/fetch/close` for real CDC clients.

## [0.10.8] - 2026-06-16

### Fixed (P0)
- **SIGTERM now unblocks `accept()`**: a shutdown watchdog fiber closes the listener socket as soon as `shutdown.isShuttingDown()` becomes true, causing the blocking `accept()` to return immediately with `SocketNotListening`. Previously the server would wait for a new connection (or never exit) after receiving SIGTERM/SIGINT.
- **`shutdown.zig` compile error on Zig 0.17**: `handleSignal` signature and `sigemptyset()` call now use `std.posix.SIG` / `std.posix.sigemptyset()` instead of the removed `c_int` / `empty_sigset` API.

## [0.11.1] - 2026-06-13

### Added
- **Codegen regression tests**: 5 new tests using `std.zig.Tokenizer` to verify generated model/service/handler/routes are syntactically valid Zig. Includes a meta-test that runs all 4 generators across 5 schemas (simple, nullable, defaults, unicode, many columns). Total codegen tests: 17 (all pass).
- **`zf check --heal` expanded**: 6 patterns now (was 4) — added `allocator.dupeZ` → `allocSentinel` and `std.fmt.bufPrintZ` → `bufPrint` patches.
- **`.claude/skills/zfinal-evolve.md`**: AI playbook for evolving the ZFinal framework — SemVer decision tree, release checklist, AGENTS.md update triggers, deprecation workflow, cross-cutting refactor checklist, skill maintenance, anti-patterns, templates.

## [0.11.0] - 2026-06-13

### Added (AI-friendliness milestone)
- **`zf check --heal`**: auto-patches 4 common compile errors:
  - Stale `pool_ref`/`token_ref`/`limit_ref` → new `getPool()`/`getTokenMgr()`/`getRateLimiter()` pattern
  - Missing getter functions in `deps.zig` (appends them)
  - `callconv(.C)` → `callconv(.c)` (Zig 0.17 lowercase)
  - `var` → `const` for never-mutated spawn/test returns
  - Verified: 82 files patched on first run, 0 on second (idempotent).
- **`zf check --ai-zones`**: reverse index of AI-editable files. Lists every `.zig` under `src/` with `// ai-edit-zone` markers or in `ext/` dir; marks `.gen.zig` files as AI-LOCKED.
- **`examples/README.md`**: index of AI-edit zones per example. Each example documents which files AI can edit vs regenerate.

## [0.10.9] - 2026-06-13

### Added (AI friendliness)
- **`.claude/skills/zfinal-debug.md`**: comprehensive compile-error → fix-pattern lookup for AI agents. Covers DB/Server/Zig 0.17/Codegen/Common Recipes/Decision Tree.
- **`zf crud:sql --explain --dry-run`**: AI-friendly planning mode. Prints full table structure, primary keys, module paths, generated files, ai-edit-zones, and decision rationale. `--dry-run` exits without writing files.

### Fixed
- **ruoyi-gen stale generated code**: rewrote 48 handler.gen.zig files to use new `getPool()`/`getTokenMgr()`/`getRateLimiter()` pattern. Updated `deps.zig` with getter functions. Full build now green.
- **ConnectionPool getter**: use `@as(*ConnectionPool, @ptrCast(&pool))` to resolve comptime value issue in Zig 0.17.

## [0.10.8] - 2026-06-13

### Added
- **`zfinal.StaticAdmin`**: single-binary admin deployment via `@embedFile`. Embed all admin HTML files at compile time — no external files, CDN, or config needed. One binary runs anywhere (VPS, container, edge).
- **`examples/standalone-admin/`**: runnable demo that embeds 3 admin HTML files (users/posts/comments) at build time. Build with `zig build run-standalone-admin`, deploy with `scp zig-out/bin/standalone-admin user@vps:/opt/app/`. Binary is ~5-8 MB with SQLite included.

### Changed
- **`server.zig`**: graceful shutdown replaced `group.cancel(io)` panic with active-connection drain loop. `shutdown.registerHandlers()` now works for SIGTERM/SIGINT.

## [0.10.7] - 2026-06-13

### Fixed (P0)
- **Graceful shutdown panic**: `group.cancel(io)` panics on aarch64-macos when `handleConn` fibers have active cancelation waiters (`assert(g.token.raw == null)`). Replaced with an active-connection drain loop that waits for `active_conns` to reach zero before returning. The listener is already closed by `defer`, so no new connections arrive. Existing connections drain naturally via keep-alive timeout or `max_requests_per_conn`.

### Changed
- `shutdown.registerHandlers()` is now available for SIGTERM/SIGINT graceful shutdown (was previously commented out due to the panic).

## [0.10.6] - 2026-06-13

### Fixed (P0)
- **Worker-thread MySQL connection failure**: `ConnectionPool.init()` now eagerly pre-creates ALL `max_connections` DB connections on the calling thread (typically main). Worker threads no longer trigger `DB.init` → `mysql_real_connect` in their own TLS context, avoiding the Zig 0.17 `std.Thread.spawn` aarch64-macos TLS/errno corruption bug. `acquire()` only pops from the pre-created available list.

## [0.10.5] - 2026-06-13

### Added
- **`zfinal.WechatPlugin`**: unified plugin wrapper for the [zwechat](https://github.com/chy3xyz/zwechat) SDK. Provides unified entry for all WeChat business modules (official account, mini program, pay, work/enterprise, open platform). Includes lazy memory cache, optional Redis cache, and official account server callback handler (`serveOA`). Manual integration — see plugin docstring for setup steps.

### Changed
- **ruoyi-gen example**: temporarily disabled (pending `*ConnectionPool` type update for generated handlers).

## [0.10.4] - 2026-06-13

### Fixed (P0)
- **ConnectionPool struct copy corrupts mutex/cond**: `ConnectionPool.init()` now returns `!*ConnectionPool` (heap-allocated) instead of `!ConnectionPool` (value). Eliminates the struct copy that drops `pthread_mutex_t`/`pthread_cond_t` internal flags on aarch64-macos. `deinit()` frees the heap allocation.

### Changed
- **`deps.zig` pool type**: `pub var pool: *zfinal.ConnectionPool` (pointer, not value). Added `getPool()` / `getTokenMgr()` / `getRateLimiter()` getter functions (already used by codegen template).
- **`Worker.zig`**: fixed `Box` struct pattern in `spawnSafe` for type unification across calling conventions.

## [0.10.3] - 2026-06-13

### Added
- **`zfinal.Worker` module**: native `pthread_create` thread spawn for aarch64-macos. Works around Zig 0.17 `std.Thread.spawn` TLS/errno bug that corrupts `mysql_real_connect` after the first call in spawned threads. Pattern: define a `Ctx` struct with a `run(raw: *anyopaque) callconv(.c) ?*anyopaque` function, allocate on heap, spawn via `Worker.Thread.spawn`.
- **`zfinal.Worker.spawnSafe`**: wraps the platform-specific logic — uses `pthread_create` on aarch64-macos, `std.Thread.spawn` elsewhere.

## [0.10.2] - 2026-06-13

### Fixed (P0)
- **ConnectionPool cross-thread mutex (aarch64-macos)**: `PTHREAD_MUTEX_INITIALIZER` on ARM macOS is a 64-byte struct with magic bytes (`0x32AAABA7`). Struct copy via `pool.* = init()` loses init flags, causing `pthread_mutex_lock` to silently fail. Symptoms: `Lost connection to MySQL server at 'reading initial communication packet'` when worker threads acquire connections. Fix: `pthread_mutex_init` / `pthread_cond_init` called at runtime via new `src/db/mutex_init.zig` wrapper.

### Assessed (no framework change needed)
- **Bug 3**: TokenManager `exists` lock contention → already fixed in v0.9.9.
- **Bug 4**: `DB.deinit` takes `*DB` → use `var db` (not `const`) to get mutable reference. Zig convention: deinit takes mutable self.
- **Bug 2**: child-thread `DB.init` TLS interaction with MySQL client library → workaround is to pre-init all connections at thread entry, not in subsequent calls. Framework behavior is correct.

## [0.10.1] - 2026-06-13

### Changed
- **ConnectionPool**: documented pthread_mutex value-copy safety. `PTHREAD_MUTEX_INITIALIZER` static init + value-copy is safe on macOS/Linux/glibc/musl. Doc comment describes mitigation path if platform-specific hangs occur.

### Investigated (no action)
- **PollerConfig / SyncTask string lifetime**: not in ZFinal framework — these are in a downstream project (test_final) and already fixed there.

## [0.10.0] - 2026-06-13

### Added
- **Cross-platform MySQL/PG include paths**: build.zig now auto-detects platform and uses appropriate default paths (macOS homebrew vs Linux system paths). User-overridable via `--mysql-include <path>` and `--pg-include <path>`.
- **Linux `install.sh`**: auto-detects MySQL/PG headers on Linux, enables `-Ddriver_mysql=true` / `-Ddriver_pg=true` when found, prints `apt install` / `yum install` instructions when headers are missing.

### Fixed
- **`-Ddriver_mysql=true` panic (Linux)**: previously hardcoded `/opt/homebrew/include` paths caused build to fail on non-macOS. Now falls back to `/usr/include/mysql` (and mariadb variant) on Linux.

## [0.9.9] - 2026-06-13

### Fixed
- **`build.zig` hardcoded homebrew paths**: `b.path("/opt/homebrew/...")` resolves relative to build.zig, causing a panic when ZFinal is consumed as a dependency. Replaced with `.cwd_relative` LazyPath for MySQL/PG translate-C include paths (`-Ddriver_mysql=true` / `-Ddriver_pg=true`).
- **TokenManager `exists` lock contention**: `exists()` held the mutex during `validate()`'s `cleanExpired()` O(n) scan, causing contention on hot paths (logout, CSRF check). Removed the mutex from `exists()` — it's a read-only check on a token that's protected by TTL-based expiry. Near-expiry tokens may briefly return `true` but cause no security regression.

## [0.9.8] - 2026-06-13

### Added
- **`examples/htmx-admin-demo/`**: self-contained multi-table admin UI demo. Serves pre-generated vben-style admin HTML for 3 tables (users, posts, comments) with multi-table sidebar nav. Run with `zig build run-htmx-admin-demo`, open `http://localhost:8080/admin/users`. Zero generated code imports — just the framework + admin HTML.
- **`public/` directory**: pre-generated admin HTML files (3 tables × 3 files each + multi-table layout). Regenerated with `zf admin examples/htmx-admin-demo/schema.sql --out public`.

### Fixed
- **codegen service template**: searchable_columns arg was at position 18 but template expected it at position 9. Fixed arg ordering so generated service.zig has correct `searchable_columns()` body instead of pascal name.
- **`deps.zig`**: added `getPool()`, `getTokenMgr()`, `getRateLimiter()` accessor functions for generated handler import compatibility.

## [0.9.7] - 2026-06-13

### Added
- **Multi-table sidebar nav**: each generated `admin.html` now includes a sidebar listing ALL tables in the project, with the active table highlighted. Navigate between `users`, `posts`, `comments` without leaving the admin shell.
- **Alpine-driven search**: the search bar in `admin.html` uses Alpine `x-data` with a `loadRows()` function that fetches `/<table>/list?q=...` and renders results via `x-for`. The input has `@input.debounce.300ms` and `@search-debounced` event dispatch.
- **Backend `search` function in `service.zig`**: takes a `q` string and LIKE-searches all TEXT columns (skips INT/BOOLEAN/etc.). New `searchable_columns()` comptime function lists searchable columns; AI can trim it in the ai-edit-zone.
- **`list` handler reads `q` query param** and routes to `service.search` when present. Falls back to `findAll` on empty.

### Changed
- **`AdminFiles` struct**: dropped the `layout` field; each per-table `admin.html` is now a full page (layout + list) so users can navigate directly to `/<table>`.
- **Removed redundant shared `admin_layout.html`**: each per-table page already contains the layout.
- **Test count**: 11 → 12 codegen tests (added multi-table sidebar and TEXT-only searchable tests).

## [0.9.6] - 2026-06-13

### Added
- **`zf crud:sql <file> --admin`**: One command emits Zig (model/service/handler/routes) AND vben-style admin HTML together.
- **Manifest `ui` metadata**: each field in the `--json` manifest now includes `input` (number/text/checkbox/date/datetime-local), `label_zh`, and `required` flags.
- **`doc/admin_template.md`**: long-form walkthrough of the vben admin generator — design tokens, field-type mapping, AI edit zones, custom styling.

### Fixed
- **SQL parser**: column types were captured with trailing `)` from the closing paren of `CREATE TABLE`. Now correctly stops at `)`.

### Changed
- **`admin_templates` and `csql_*.zig`**: refactored to import `codegen` as a named module instead of a file path, enabling the admin templates tests to run in `zig build test-zf`. Test count: 6 → 10.

## [0.9.5] - 2026-06-13

### Added
- **`zf admin <sql>` command**: emits vben-style admin HTML for every table in a SQL schema. 4 templates per table: `admin.html` (list + table + pagination + modal), `admin_form.html`, `admin_row.html`, plus a shared `admin_layout.html` (topbar + dark sidebar).
- **All assets via CDN**: Tailwind CSS (Play CDN with JIT), HTMX 1.9.10, Alpine.js 3.13. No local build step.
- **vben design tokens**: deep blue (`#2b85e4`), dark sidebar (`#001529`), gray content area (`#f0f2f5`), all wired through `tailwind.config`.
- **SQL-type → input mapping**: INTEGER→number, REAL→number-step, BOOLEAN→checkbox, DATE→date, DATETIME→datetime-local, TEXT>200→textarea, TEXT→text.
- **AI edit zones in HTML**: each generated template contains `// ── ai-edit-zone: ...` markers for search filters, row actions, form layout, topbar, sidebar.
- **`examples/htmx-admin/`**: runnable demo with `main.zig`, `schema.sql`, and generated `public/` directory. Run with `zig build run-htmx-admin`.

## [0.9.4] - 2026-06-13

### Changed
- **`README.md` and `README_CN.md`**: rewritten as AI-first landing pages. Top banner directs AI agents to `zfinal-onboarding`, 5-step speedrun table at the top, "Why ZFinal is different" comparison table, embedded JSON manifest example, updated badges and version (v0.9.3, 145 main + 6 codegen tests).

## [0.9.3] - 2026-06-13

### Added
- **`zfinal-onboarding` skill**: 30-second orientation any AI agent reads first when it encounters a ZFinal project. Includes the 5-command speedrun, skill-routing table, and forbidden actions.
- **Sub-agent `zfinal-developer`**: `.claude/agents/zfinal-developer.md` bundles the onboarding + playbook + hard rules into a single auto-dispatched unit. Hosts that support sub-agents will pick it up via the `description` field.
- **AI-first landing page**: `doc/index.md` rewritten with a dual-audience table (AI agents vs humans) and a complete project map.
- **AGENTS.md top banner**: declares ZFinal as an AI-first framework and points agents at `zfinal-onboarding` on first contact.

### Changed
- **`zfinal-evolution` skill**: now has frontmatter (`name`, `description`) so it is discoverable by skill loaders.

## [0.9.2] - 2026-06-13

### Added
- **`zfinal.ZfTool`**: In-process wrapper around the code generator. `ZfTool.manifestFromSql` produces the same JSON manifest as `zf crud:sql --json`, callable from any in-framework code (aichat, embedded assistants). Exposed at `src/aichat/zf_tool.zig`.
- **AI-friendly SQLite constraint errors**: `SQLiteDB.execParams` / `queryParams` now return typed errors (`UniqueViolation`, `NotNullViolation`, `ForeignKeyViolation`, `CheckViolation`, `DuplicatePrimaryKey`) with `table` and `column` extracted from the SQLite message. Lets AI agents show "users.email already exists" instead of "SQLite step failed: 19".
- **Code generator regression tests**: `tools/zf/codegen_test.zig` with 6 tests covering model/service/handler/routes templates, SQL parsing, and JSON escaping. Run with `zig build test-zf`.

## [0.9.1] - 2026-06-13

### Added
- **`doc/ai-quickstart.md`**: Long-form 5-minute walkthrough of the AI-driven development flow — schema → `zf crud:sql --json` → edit ai-edit-zones → verify → run.
- **`examples/ai-blog-5min/`**: Runnable 5-minute AI speedrun demo with `main.zig`, `schema.sql`, and `ZF_GEN.md`. Run with `zig build run-ai-blog-5min`.

## [0.9.0] - 2026-06-13

### Added
- **AI protocol layer**: `zf crud:sql <file> --json` and `zf g <type> <name> --json` emit machine-readable manifests listing generated files, AI edit zones, fields, and next steps. Lets AI agents parse what was created and where to edit.
- **AI edit-zone markers**: `model.zig`, `service.zig`, and `handler.zig` templates now include `// ── ai-edit-zone: ...` blocks so AI agents know exactly where to add business logic vs. leave generated boilerplate untouched.
- **Project skill `zfinal-ai-playbook`**: Captures the standard "add a feature" script (read → generate → edit zones → verify → ship) for AI agents.
- **CLAUDE.md skill routing**: New `## Skill routing` section so future agents pick the right skill by trigger.

### Changed
- **`zf` subcommand surface**: `zf crud:sql` and `zf g` now accept `--json` to switch to machine-readable output.

## [0.8.2] - 2026-06-13

### Fixed
- **Zig 0.17-dev test runner crash**: `zig build test` now runs the compiled test binary directly to avoid the `EndOfStream` panic in server-mode runner on `0.17.0-dev.813+2153f8143`. Tests pass: 144 passed; 2 skipped; 0 failed.

### Changed
- **Code style**: Applied `zig fmt` across 346 Zig files in `src/`, `test/`, `tools/`, `examples/`, and `benchmark/`.

### Added
- **Project skill `zfinal-health`**: Documents the ZFinal health-check workflow, Health Stack commands, and the Zig 0.17-dev runner workaround.
- **CLAUDE.md**: Added Health Stack and ZFinal development notes.

## [0.8.0] - 2026-06-01

### Added
- **Zig 0.17 migration**: Full compatibility with Zig 0.17.0-dev.387.
  - `@cImport` → `b.addTranslateC` build-system translate-c (6 files).
  - `std.fmt.bufPrintZ` → `bufPrint` + manual null termination.
  - `allocator.dupeZ` → `allocSentinel` + `@memcpy`.
  - `std.ascii.indexOfIgnoreCase` → `startsWithIgnoreCase`.
- **Safe deps accessors**: `getPool()`, `getTokenMgr()`, `getRateLimiter()` with panic-guarded init checks.
- **Model validate()**: Auto-generated NOT NULL field validation for generated models.
- **Model safeFields**: API response field whitelist for generated models.
- **Handler PATCH**: Partial update endpoint in generated handlers.
- **Service update()**: Comptime `inline for` field merging for non-null/non-zero fields.
- **csv_kit.zig**: RFC 4180 CSV parser and formatter with BOM detection.

### Changed
- **Router**: O(1) HashMap fast path for static routes (90%+ of routes). Parameterized routes fall back to linear scan.
- **Server**: `thread_count` config now actually passed to `Threaded.init` (was logged but ignored).
- **Interceptor**: Pre-allocated chain capacity with `ensureTotalCapacity` + `appendAssumeCapacity`.
- **CSRF Token**: Removed dead `Token.value` field. `generate()` 3 allocs → 2 allocs.
- **Deps**: `pub var = undefined` → `?T = null` with safe accessors.
- **Generator**: `parseInt`/`parseFloat` failures return 400 Bad Request with field name.
- **Generator**: `handler.update()` calls `service.update()` (comptime field merge + validate).
- **Generator**: Deps injected via `getPool()`/`getTokenMgr()`/`getRateLimiter()` instead of raw pointer refs.
- **Generator**: `service.deleteOne()` added to generated modules.
- **AGENTS.md**: Updated for Zig 0.17 and new generator patterns.

### Fixed
- **Memory leaks (5)**: `context.zig` compressBody (buf+compressor), `template.zig` filter dupe,
  `csv_kit.zig` toOwnedSlice × 3, `codegen.zig` Table.name, htmx.zig page_allocator.
- **Thread safety (16)**: 13 `catch{}` → `try`/`@panic` on mutex locks, 2 DB rollback panics,
  1 RandomKit benign-race fast path.
- **Path traversal (3)**: `renderFile()`, `loadFromFile()`, `renderFile` size limit.
- **Security (2)**: Password buffer zeroing (mysql, postgres), DoS file size guard.
- **Bugs (6)**: `paginate()` page=0 underflow, page_size=0 div-by-zero (×3),
  errdefer double-toOwnedSlice, server double await, deps init safety.
- **Examples (2)**: htmx data race (TodoStore mutex), ruoyi-gen connection leak.
- **Mutex consistency**: `token.zig`, `session.zig`, `thread_pool.zig`, `ws/manager.zig`,
  `plugin/cache.zig`, `captcha.zig` → `std.Io.Mutex`.
- **Deinit poisoning**: 9 struct deinit functions with `self.* = undefined`.
- **Rate limiting**: `catch{}` → `return err(429)` with error name.

### Quality
- Tests: 142 pass, 2 skip, **0 leaks** (was 3 leaks).
- 80+ anti-pattern fixes across 6 rounds of systematic hardening.
- ZBP quality rating: B+ → A-.

## [0.3.0] - 2026-05-12

### Added
- **Observability**: Structured logger with key=value fields, pluggable backends (stderr/writer), compile-time log level filtering (`-Dlog-level=debug|info|warn|err`). Health endpoint with request counters, uptime, and error ring buffer via `Metrics`.
- **Production example**: `examples/production/main.zig` demonstrating logging, health checks, CSRF, rate limiting, and CORS.
- **Integration tests**: 7 new tests covering router dispatch, CSRF token flow, captcha validation, interceptor chain, metrics pipeline.
- **Graceful shutdown**: `src/core/shutdown.zig` with SIGTERM/SIGINT handler and atomic shutdown flag.
- **Redis network layer**: Full RESP protocol implementation over TCP. Real `connect()`/`disconnect()`, all commands (PING/GET/SET/DEL/EXPIRE/EXISTS/FLUSHDB/SETEX).
- **PostgreSQL driver**: Full libpq driver in `drivers/postgres.zig` with `$N` parameter binding, query iteration, health checks.
- **MySQL driver**: Full mysqlclient driver in `drivers/mysql.zig` with prepared statements, `MYSQL_BIND` I/O binding, row iteration.
- **WebSocket enhancements**: Automatic ping/pong handling, proper close handshake with status codes, `sendPing()`/`sendClose()`.
- **Template engine**: Recursion depth limit (`MAX_DEPTH=32`), path traversal sandboxing in `loadTemplateFile`.
- **JSON depth validation**: `JsonKit.validateDepth()` with `MAX_JSON_DEPTH=64` for DoS prevention.
- **Production audit**: Complete `PRODUCTION_AUDIT.md` with 51 findings, severity ratings, and fix roadmap.
- **Plugin maturity tiers**: Stable/stub/experimental classification in README.

### Changed
- **Server architecture**: Merged SyncServer + AsyncServer into a single fiber-based async server. Uses `Io.Threaded` + `Group.async` with error-isolation pattern. Zero heap allocation per connection. Keep-alive support. Removed `async_server.zig`.
- **ThreadPool**: Workers now use blocking `pop()` with condition variable instead of busy-spinning (100% CPU idle → near-zero). ThreadPool remains as standalone utility for CPU-bound tasks.
- **Logger**: Replaced all `std.debug.print` calls in core modules with structured Logger calls.
- **Rate limiter**: Uses real socket address by default; proxy headers require explicit `trust_proxy_headers = true`.
- **FileKit**: Added `validatePath()` for path traversal prevention.
- **Cron**: Replaced 30-day month assumption with proper `EpochSeconds` calendar math. `nextRun()` now returns `?i64`.
- **Context**: Configurable `max_body_size` (was hardcoded 2MB/10MB). `remote_addr` field for real client IP tracking.
- **Plugin system**: `startAll()` rolls back on failure. `stopAll()` continues on error and returns void.
- **P2P**: `thread.detach()` → `thread.join()`. `running` is now atomic.
- **MQTT**: `running` field changed to `std.atomic.Value(bool)`.
- **Cache**: Added mutex for thread-safe memory backend operations.

### Fixed
- **C1**: PRNG seeded with constant `0` → replaced with OS CSPRNG (`arc4random_buf`/`getrandom`).
- **C2**: SQL injection via `findWhere` → `where_sql` made `comptime`. `ParamQuery.toSql()` gated to Debug-only.
- **H1**: Set-Cookie dangling stack pointer in `renderText`/`renderJson`/`renderHtml` → heap allocation + defer free.
- **H2**: Context.deinit memory leaks (query_params, attributes keys/values) → iterate and free before deinit.
- **H3**: Token and captcha never expired → implemented real `TimeKit.now() - created_at > ttl` logic.
- **H4**: Session `getAttr` data race → returns owned copy instead of borrowed slice.
- **H5**: `ParamQuery.toSql()` SQL injection vector → `@compileError` gate in non-Debug mode.
- **H6**: ThreadPool 100% CPU idle spin → blocking `pop()` with condition variable + shutdown signal.
- Template for-loop body never rendered for simple arrays → inline variable substitution.
- Template `{% extends %}` blocks HashMap memory leak → proper ownership transfer + deinit.
- Router `addWithMethodAndInterceptors` missing errdefer → added for parsed segments/param_names.
- Session `setAttr` leak on `put` failure → errdefer on key/value copies.
- Validator `validatePattern` was TODO stub → implemented with `RegexKit.match()`.
- Connection pool now performs health checks before returning connections.
- Rate limiter HashMap no longer grows unboundedly (periodic stale entry cleanup).

### Security
- OS CSPRNG for all random operations (tokens, captcha, UUID, session IDs).
- `comptime` WHERE clause enforcement for SQL injection prevention.
- Path traversal sandboxing in template engine and FileKit.
- Real client IP for rate limiting (not spoofable proxy headers).
- Connection pool health checks prevent stale connection use.
- Request body size limits configurable via `Context.max_body_size`.
- 90 tests (88 pass, 2 skip, 0 fail), zero known vulnerabilities in core path.

## [0.2.0] - 2025-12-30

### Added
- AsyncServer with fiber-based concurrency (`std.Io.Threaded` runtime).
- ThreadPool for sync server with condition variable-based blocking.
- Template engine: conditionals, loops, includes, layout inheritance, filters.
- Cache system with memory and Redis backends.
- Cron job scheduler with expression parser.
- i18n support with pluralization, interpolation, and locale detection.
- Logger with structured output and JSON format option.
- 17 utility kits (StrKit, HashKit, DateKit, JsonKit, FileKit, etc.).

### Changed
- Upgraded to Zig 0.16 with full IO reform compatibility.
- Improved build system with example runners and CLI tool targets.

### Fixed
- Zig 0.16 API migration issues (IO instance, Timestamp, ArrayList, Thread).
- Test deadlocks from mutex usage with `std.testing.io`.

## [0.1.0] - 2024-12-03

### Added
- Core HTTP server based on Zig standard library.
- RESTful routing system with path parameters.
- Active Record ORM with SQLite support.
- Interceptor/AOP support.
- CLI tool `zf` for project scaffolding.
- Session management and cookie support.
- WebSocket support.
- Static file serving and file upload.
- Comprehensive English and Chinese documentation.
