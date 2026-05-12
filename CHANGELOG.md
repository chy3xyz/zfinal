# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- **ThreadPool**: Workers now use blocking `pop()` with condition variable instead of busy-spinning (100% CPU idle → near-zero).
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
