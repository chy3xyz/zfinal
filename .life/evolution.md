# Evolution Journal

Chronological record of every significant change. Append-only. Newest first.

---

## 2026-07-23 — score lift: JWT RS256 verify + OffsetFetch/LeaveGroup

**Session**: Continue score improvements
**Changes**:
1. `jwt.verifyRs256` / `jwtVerifyRs256` — OIDC/gateway RS256 verify (PEM/DER); fixtures under `src/auth/testdata_*`
2. RobustMQ OffsetFetch + LeaveGroup wire; `KafkaConsumer.fetchCommittedOffset` / `leave`
3. PRODUCTION_AUDIT scorecard bump (Security/Docs/Optional)
**Tests**: `zig test src/auth/jwt.zig` (4) + `zig build test` (225 passed; 11 skipped) + install-zf

---

## 2026-07-23 — zone merge + check --root + ports-l2 example

**Session**: P1/P2 backlog items 1–3
**Changes**:
1. `tools/zf/zone_merge.zig` + `safeWrite` preserves matching `ai-edit-zone` bodies (else `.gen.new`)
2. `zf check --prod --root <dir>` — portable contract scan; reference root FAIL-strict
3. `examples/ports-l2` L2 DI demo + `zig build run-ports-l2`
**Tests**: `zig test tools/zf/zone_merge.zig` (3) + `zig build test-zf` (27) + `zig build test` (224 passed; 11 skipped) + `zf check --prod` / `--root examples/ports-l2` + `ports-l2` binary

---

## 2026-07-23 — ports codegen + RobustMQ JoinGroup

**Session**: `zf g port` + Kafka consumer group membership
**Changes**:
1. `tools/zf/cmd_port.zig` + `zf g port store|cache|bus` wired in `main.zig` (`--json`/`--force`)
2. RobustMQ: JoinGroup/SyncGroup/Heartbeat wire + `KafkaConsumer.join`/`heartbeat`; OffsetCommit uses generation/member
3. Docs: `codegen.md`, `progressive_architecture.md`, `robustmq.md`, CHANGELOG
**Tests**: `zig build install-zf` + `zf g port bus --json` smoke + `zig build test` (224 passed; 11 skipped) + `zig build test-zf`

---

## 2026-07-23 — P1: zf split phase3 (crud/fixture/bench)

**Session**: Continue modularizing `tools/zf/main.zig`
**Changes**:
1. `cmd_crud.zig` — `handleCrud` / `handleCrudFromSql` / `handleCrudZent` / `handleCrudFromDsn` / `handleAdmin` + helpers (`writeGeneratedFiles`, `emitJsonManifest`, `bootstrapProject`, `modulePath`, `singularize`)
2. `cmd_fixture.zig` / `cmd_bench.zig` — fixture + HTTP bench handlers
3. `zf_shared.zig` — `appendJsonString` + `writeAiConfigs` (shared by scaffold + CRUD bootstrap)
4. `main.zig` dispatcher ~2754 → ~1372 lines
**Tests**: `zig build install-zf` (recompiled) + `zig build test` (220 passed; 11 skipped) + `zig build test-zf` (26 passed) + crud:sql smoke

---

## 2026-07-23 — Kafka classic range rebalance + score lift

**Session**: Multi-instance Kafka consume + JWT RS256 / OffsetFetch
**Changes**:
1. `KafkaConsumer.join` — classic range assignor over `partition_count`; SyncGroup assignment parse; multi-partition `poll`/offsets
2. JWT RS256 verify; OffsetFetch/LeaveGroup; zone-preserving regen; `zf check --prod --root`; ports-l2 example
3. Docs: `robustmq.md` / `PRODUCTION_AUDIT` / CHANGELOG
**Tests**: `zig build test` → 227 passed; 11 skipped; 0 failed

---

## 2026-07-23 — P1: zf split phase2 (migrate/openapi/check) + RobustMQ OffsetCommit

**Session**: Continue improvement backlog
**Changes**:
1. `cmd_migrate.zig` / `cmd_openapi.zig` / `cmd_check.zig` — extract from `main.zig` (with `zf_shared`/`zf_db`)
2. RobustMQ: OffsetCommit wire + `commitLocal`/`commit`; docs nail NATS-first L3 consume
3. CHANGELOG / PRODUCTION_AUDIT residual gaps updated
**Tests**: `zig build install-zf` + `zig build test` + `zig build test-zf`

---

## 2026-07-22 — P0 hardening: version SSoT + write timeout + audit refresh

**Session**: Execute improvement backlog P0 (+ write-timeout authenticity)
**Changes**:
1. `src/version.zig` — single semver/tag source; build options + manifests consume it; zon sync test
2. `TimedWriter` — wall-clock `write_timeout_ms` from first drain per request (Zig dropped `net_write`)
3. Docs: regeneration = `.gen.new` / `--force`; `PRODUCTION_AUDIT` / `SECURITY` / agent docs → 0.20.3
**Tests**: `zig build test` + `zig build test-zf`

---

## 2026-07-20 — v0.13.10: ZFinal × zent (e-commerce / social)

**Session**: Introduce zent like zigmodu — orthogonal ORM for graph-heavy domains
**Changes**:
1. `doc/zent.md` — when to use zent vs zf Model; anti-mix-stack rules
2. `examples/zent-shop` — User/Product/Follow/Post + HTTP smoke
3. `zig build run-zent-shop` convenience (sibling `../zent`)
**Tests**: example build + curl smoke on :18200 OK

---

## 2026-07-19 — v0.13.9: QueueNatsClient → stable

**Session**: Promote NATS from experimental; drop nats.zig optional dep
**Changes**:
1. `nats_client.zig` — zero-dep NATS wire (from zigmodu)
2. `QueueNatsClient` stable root export + URL parse; experimental alias kept
3. Docs `doc/nats.md`, ADR-005
**Tests**: run after change

---

## 2026-07-19 — v0.13.8: RobustMQ / Kafka connector

**Session**: Port zigmodu KafkaConnector; connect RobustMQ besides NATS
**Changes**:
1. `src/plugin/robustmq.zig` — Kafka wire + `QueueRobustMQClient` façade
2. Stable root exports; docs `doc/robustmq.md`; L3 bus prefers RobustMQ
3. NATS remains `experimental.QueueNatsClient`
**Next**: Full Fetch RecordBatch decode; optional consumer-group join

---

## 2026-07-19 — Docs: scale-out + progressive architecture

**Session**: Encode 千万级支撑方案; reverse into L0→L3 code architecture
**Changes**:
1. `doc/scale_to_millions.md` — topology, ZFinal constraints, capacity, roadmap
2. `doc/progressive_architecture.md` — L0–L3 directories, ports/adapters, checklists
3. Cross-links from architecture_best_practices, index, AGENTS, READMEs, framework skill
**Next**: Optional example skeleton under `examples/` mirroring L2 ports (when requested)

---

## 2026-07-19 — Docs: architecture best practices

**Session**: Write architecture best practices into project docs
**Changes**:
1. Added `doc/architecture_best_practices.md` (layers, AI zones, plugins, security, anti-patterns)
2. Linked from `doc/index.md`, `AGENTS.md`, README / README_CN, `zfinal-framework` skill
**Next**: Keep doc in sync when stable/experimental plugin set changes

---

## 2026-07-19 — v0.13.7: P2P + remaining plugins; Zig 1422

**Session**: Continue P2P/HttpClient/Config/OAuth2/etc.; adapt to Zig 0.17.0-dev.1422
**Changes**:
1. P2P: spin-mutex helpers, safe peer snapshot, gossip `announce` test + mesh broadcast test
2. HttpClient: `Writer.Allocating` for `response_writer` (`?*Writer` on 1422)
3. zf migrate: `std.hash.Crc32` (ISO-HDLC) replaces removed `hash.crc.Crc32`
4. CI / dna / audit pin → `0.17.0-dev.1422+e863bf3be`
**Tests**: 176 passed; 2 skipped; 0 failed (`zig build` + `test-zf` OK)
**Next**: MQTT subscribe/QoS; optional NATS behind `-Denable-nats`; keep-alive when Zig http.Server fixed

---

## 2026-07-19 — v0.13.6: Promote plugins to stable

**Session**: CircuitBreaker, Queue, DID, Agent, MetricsExporter, MQTT → stable
**Changes**:
1. New `circuit_breaker.zig`, `metrics_exporter.zig`; rewrite `queue`/`did`/`agent`/`mqtt`
2. Root exports updated; experimental keeps P2P/NATS/compat stubs
3. 165 passed / 2 skipped
**Next**: MQTT subscribe; optional NATS behind `-Denable-nats`
**Tests**: 165 passed; 2 skipped; 0 failed

---

**Session**: Raise production score from ~75/94 claim to verified 95%
**Changes**:
1. Trusted-proxy IP policy (`ClientIpOptions`) — rate limit + access log no longer trust spoofable headers by default
2. `zfinal.experimental.*` namespace for MQTT/Agent/DID/P2P/Queue/stubs
3. Redis loop-read + NeedMoreData + size cap + 5 parseResp unit tests
4. Token/Captcha `purgeExpired`; Cookie HttpOnly+SameSite defaults; Secure opt-in
5. Context path-safety tests + renderFile last-chunk fix; Metrics healthHandler type fix
6. PRODUCTION_AUDIT rewritten; README badges 95%; CI ReleaseSafe smoke
**Errors**: healthHandlerFor capture of non-comptime pointer — fixed with `comptime metrics: *Metrics`
**Next**: Optional PG/MySQL CI matrix; revisit keep-alive when Zig http.Server is fixed
**Tests**: 154 passed; 2 skipped; 0 failed

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
