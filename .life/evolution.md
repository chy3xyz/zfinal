# Evolution Journal

Chronological record of every significant change. Append-only. Newest first.

---

## 2026-05-12 — v0.4.0: Framework Unification & AI-Native Codegen

**Session**: Production hardening wave 2
**AI Agent**: Claude Opus 4.7
**Fingerprint**: d96b03c

### Major Changes

1. **Server merge**: SyncServer + AsyncServer → single fiber-based Server (Io.Threaded + Group.async). Error-isolation pattern: `acceptLoopImpl` returns full error set, `acceptLoop` wrapper constrains to `Cancelable!void`. Zero heap per connection.

2. **Schema-driven codegen**: Created `tools/zf/codegen.zig` — SQL parser supporting SQLite/MySQL/PostgreSQL dialects, Zig type mapper, CRUD code generator (Model + Controller + Routes + Tests). New commands: `zf crud:sql`, `zf crud`.

3. **3-mode AI workflow**: Mode 1 (greenfield DB design), Mode 2 (existing SQL), Mode 3 (legacy migration from Java/PHP/Go/Rust). SKILL files updated with trigger phrases, discovery commands, and self-contained execution guide.

4. **WebSocket hardening**: Close handshake (send ack, close TCP), ping/pong auto-handling, frame fragmentation + reassembly (`frag_buf`, `sendFragmented()`).

5. **Redis client**: Full RESP protocol over TCP. `command()` builds RESP arrays, `readResponse()` parses all 5 response types. All commands: PING/GET/SET/DEL/EXPIRE/EXISTS/FLUSHDB/SETEX.

6. **Response compression**: `Context.compressBody()` using `std.compress.flate` with gzip container. `Accept-Encoding` detection, configurable `compress_enabled`.

7. **Docker deployment**: Multi-stage Dockerfile (Alpine build→runtime), docker-compose with optional PG/Redis/Nginx.

8. **ZF CLI fixes**: `std.heap.smp_allocator`→`page_allocator`, `args_iter` exhaustion bug fixed, version string updated to 0.3.0.

9. **`.life/` system**: Project evolution memory with DNA fingerprint, evolution journal, ADR records, AI session memories.

### Architecture Decisions Made
- ADR-003: Schema-driven codegen as primary AI workflow
- ADR-004: Error-isolation pattern for Group.async
- ADR-005: Opt-in native drivers with zero-dep default

---

## 2026-05-12 — v0.3.0: Production Hardening

**Session**: Production hardening wave 1
**AI Agent**: Claude Opus 4.7
**Fingerprint**: 631c927

### Major Changes

1. **Security**: Replaced PRNG constant seed with OS CSPRNG. SQL injection prevention (comptime WHERE, Debug-only toSql). Path traversal sandbox. Connection pool health checks. Rate limiter real-IP + configurable proxy trust.

2. **Observability**: Structured Logger with key=value fields, compile-time log levels, stderr/writer backends. Health endpoint with Metrics (uptime, request counters, error ring buffer). Replaced all `std.debug.print` with Logger.

3. **Memory safety**: Fixed Set-Cookie dangling pointer (heap-allocated + defer free). Fixed Context.deinit leaks (iterate+free hashmap keys/values). Fixed Session.getAttr UAF (return owned copy).

4. **Concurrency**: ThreadPool idle spin→blocking pop+condvar. Cache mutex. MQTT/P2P atomic safety. Plugin rollback on start failure.

5. **Correctness**: Token/Captcha real expiry. CRON proper calendar math (EpochSeconds). Template recursion limit. Template for-loop body fix. Template layout blocks leak fix.

6. **Database**: PostgreSQL full libpq driver. MySQL full mysqlclient driver. Both with prepared statements, parameter binding, full row iteration.

7. **Graceful shutdown**: SIGTERM/SIGINT handler with atomic flag. `shutdown.registerHandlers()`.

8. **Documentation**: AGENTS.md rewrite, SKILL files, CHANGELOG, SECURITY.md, PRODUCTION_AUDIT.md (51 findings→all resolved).

### Architecture Decisions Made
- ADR-001: Fiber-based server over thread-pool
- ADR-002: CSPRNG over deterministic PRNG

---

## 2025-12-30 — v0.2.0: Feature Expansion

**Session**: Initial feature build-out
**Fingerprint**: 369d84f

### Major Changes
- AsyncServer with fiber-based concurrency (Io.Threaded)
- Template engine: variables, loops, conditions, includes, extends, layouts
- Cache system (memory + Redis stubs)
- Cron scheduler with expression parser
- i18n with pluralization, interpolation, locale detection
- Logger with text/JSON format options
- 17 utility kits
- Zig 0.16 upgrade with full IO reform compatibility

---

## 2024-12-03 — v0.1.0: Initial Release

**Session**: Project inception
**Fingerprint**: f2e7124

### Major Changes
- HTTP server based on Zig std lib
- RESTful routing with path params
- Active Record ORM (SQLite)
- Interceptor/AOP support
- CLI tool `zf` for project scaffolding
- Session management, cookies, file upload, WebSocket support
- 8 example projects
