## [Unreleased]

### Added
- **Module marketplace phase 2 (ADR-016)**: `zf market update` syncs the remote catalog (`https://raw.githubusercontent.com/chy3xyz/zfinal/main/marketplace/catalog.json`) to `~/.cache/zf/marketplace-catalog.json`; `zf market list|search|info` prefer the cache and fall back to the repo-local catalog; `zf market install <id>` downloads the entry's `url` tarball, extracts its `path` (skipping the GitHub archive prefix), and places plugins into `src/plugin/` or examples/modules into `vendor/marketplace/<id>/`. Supports `--dir`, `--dry-run`, `--verify`, `--registry`, `--json`.
- **Marketplace catalog schema v2**: entries now carry a `url` artifact field; `market_util.zig` provides pure, unit-tested helpers (path resolution, strip computation, cache path, query matching).
- **Declarative list query + DTO (ADR-017)**:
  - `Model.Query` — fluent, comptime-validated query builder (`eq/gt/gte/lt/lte/textEq/floatEq/boolEq/like/likeAll/orderBy/page/list/count/paginate`); column names are checked against the model's table struct at compile time, so WHERE fragments and `SqlParam[]` can never go out of sync.
  - `Context.bindQuery(&filters)` — declarative DTO binding from query params (`?i64` / `?i32` / `?f64` / `?bool` / `?[]const u8` / optional enums); missing params keep struct defaults, invalid values respond 400.
  - `Context.renderPage(page, allocator)` — unified `{data, total, page, size}` serialization plus ownership cleanup (per-item `deinit` + list free) in one call.
  - **`zf crud` column annotations**: `-- @filter` / `-- @search` / `-- @sortable` / `-- @hidden` trailing comments in `CREATE TABLE` generate a typed `Filters` struct and a `Model.Query`-based `service.list(db, f, page, size)`; the generated handler switches to `ctx.bindQuery` + `ctx.renderPage`. Un-annotated tables keep the legacy generated shape.

## [0.20.15] - 2026-08-02

### Added
- **`zfinal.ai.KeyPool`**: multi-API-key rotation (least-inflight + RR), per-key RPM /
  max_inflight, 429/401 cooldown; wired into `AiProvider.chatWith` / `chatStream`.
- **`AiConfig.api_keys` / `key_rpm` / `key_max_inflight`**: `AiRuntime` builds an owned
  `KeyPool` when multiple keys are configured.
- **`ProviderRegistry` / `ProviderSpec`**: multi-endpoint weighted pick + failover.
- **`zfinal.ai.default_deepseek_model`**: `deepseek-v4-flash` (official; `deepseek-chat` retired).
- **`McpClient` / `McpBridge` / `AiRuntime.attachMcp`**: opt-in MCP client
  (`initialize` / `tools/list`+cursor / `tools/call` / `resources/*` / `prompts/*`)
  bridged into `SkillRegistry`. Instance-owned bridge; NDJSON + Content-Length;
  **HTTP POST + SSE `data:`** (`mcpConnectHttp` / `McpHttpTransport`); response id match
  **with out-of-order id buffer**; skip notifications; skill deadline on list/call.
  Demo: `zig build run-ai-mcp`.
- **`KeyPool`**: atomic metrics + `CooldownStore` / `MemoryCooldownStore` /
  **`RedisCooldownStore`** (`zfinal.RedisCooldownStore`) for shared cooldown.

### Changed
- Docs / `aichat` tests / `zf ai --provider deepseek` default model → `deepseek-v4-flash`.
- **`AgentPlugin`**: `tools/*` + `resources/list|read` + `prompts/list|get`.
- **`SkillContext.active_tool_name`**: set by `dispatchWith` for MCP bridge handlers.
- **`zf ai --provider anthropic`**: Messages API (`ANTHROPIC_API_KEY`, default Haiku).
- README：区分 `AgentPlugin`（进程内 server）与 `McpClient`/`McpBridge`（外部 client）。

## [0.20.14] - 2026-08-02

### Added
- **`zf doctor [--json]`**: diagnose PATH/`zig-out` binary, semver vs `build.zig.zon`,
  modules/actions wiring; exit 2 on advisory issues.
- **`zf check --practice [--strict]`**: business best-practice heuristics (handler SQL/
  layering, keep-alive, envelope mix, password zeroize, DB write+Bus without Outbox);
  optional `.zfinal-check.json` `ignore` list.
- **`cmd_catalog.zig`**: single table for command parse + help (prevents missing subcommands).
- **`zf new … --json`**: machine-readable project scaffold manifest.
- **Release workflow**: upload `zf` Linux/macOS ReleaseSafe artifacts after gate.
- **`zf routes` incremental cache**: skip rewrite when `routes.zig` mtime ≥ `actions.zig`
  (bypass with `--force`).

### Changed
- **`main.zig` thinned**: scaffold/new/generate/ai/upgrade/life → `cmd_scaffold.zig`.
- **`doc/zf_cli.md`**: rewritten for v0.20.x (`routes` / `check --prod|--practice` / `doctor` / `gate`).
- **`doc/aichat.md`**: ZfTool ↔ `zf crud:* --json` manifest schema alignment.
- **Quality gate**: pin `$ROOT/zig-out/bin/zf`, assert help lists `doctor`, run `zf doctor`.
- **Exit codes**: `zf_shared.Exit` — 0 ok / 1 fail / 2 warn (`doctor`, check fail).
- **CRUD/ZfTool manifests**: shared `$schema` + semver `version` + `actions` file key.

### Fixed
- **Memory leaks (request path)**: `compressBody` no longer heap-allocates a
  never-freed flate window; performance/access-log interceptors and
  `SessionExt.setUserId` stop `allocPrint`+`setAttr` double-copy orphans;
  performance interceptor no longer `free`s map-owned `getAttr` (UAF);
  `setAttr`/`setHeader` overwrite frees prior values; `setCookieFull` /
  `ensureQueryParams` / `parseQueryIntoAllocator` / `SkillRegistry.register`
  errdefer ownership tightened.
- **`zig fmt` drift** on bus/outbox/ai/deadcode (Release CI).

## [0.20.13] - 2026-08-02

### Fixed
- **`SkillRegistry.toOpenAiFunctionsAlloc`**: drop an extra `}` so tools JSON is
  valid (DeepSeek/OpenAI Agent+tools path was returning `ProviderError`).
  Verified live with `deepseek-chat` / `deepseek-v4-flash`.

## [0.20.12] - 2026-08-02

### Docs
- Hub refresh: `doc/index.md` / `README` / `README_CN` / `AGENTS.md` /
  `best_practices` / `scale_to_millions` / `database` /
  `architecture_best_practices` — test baseline **369/17**, Outbox→Bus links,
  production score ~9.2.

### Added
- **DbOutbox live PG/MySQL** `drainOnce` roundtrip (env-gated; runs in `drivers-live`).
- **messaging-live CI**: TCP wait on :9092, fail if Redpanda down, pre-create soak topics.
- **production `ZF_OUTBOX_DB`**: durable `DbOutbox` optional; MemoryOutbox default.
- **OAuth2 `OAUTH2_LIVE`**: client_credentials smoke test + `run-oauth2` live path.
- **PRODUCTION_AUDIT** refresh (2026-08-02) for L3/messaging scores.
- **CI `messaging-live`**: NATS service + Redpanda; env-gated consume soak
  (`NATS_URL` / `KAFKA_BOOTSTRAP` / `ROBUSTMQ_URL`).
- **Live consume soaks**: NATS pub/sub asserts delivery; `QueueNatsClient` /
  `NatsBus` soak; RobustMQ produce+`KafkaConsumer.poll` soak.
- **ai-runtime**: `TokenQuota.attachDb` + `AgentAuditLog.attachDb` wired into Agent.
- **Production example L3 demo**: MemoryOutbox + MemoryBus, JWT `/internal/outbox/drain`, WS `/ws`.
- **`zf check --prod` L3 heuristics**: WARN on SQL-like lines without `tenant_id`/`app_id`;
  Bus `.publish` without Outbox/drainOnce.
- **Bus consume wiring**: `NatsBus.subscribe`/`subscribeGroup`/`poll`; RobustMQ publish+`KafkaConsumer` pairing test;
  `MemoryOutbox.drainOnce`.
- **`DbOutbox.drainOnce`**: poll → Bus.publish → mark; retries + dead-letter (`attempts` /
  `dead_at_ms`); PG/MySQL DDL + insert dialects; Prometheus gauges.
- **WS `tickIdle` / `cronTickIdle`**: periodic reap + ping hook for CronPlugin.
- **OAuth2 `mock_token_json`**: offline `exchangeCodePkce` / error-path tests.
- **P2P `setHmacKey`**: HMAC-SHA256 over frame payloads (drop on mismatch).
- **`zfinal.DbOutbox`**: durable outbox on `zfinal_outbox` (idempotent append, fetch/mark);
  docs [doc/outbox.md](doc/outbox.md).
- **WS idle / ping**: `WebSocket.idle_timeout_ms`, `WebSocketManager.pingAll` / `reapIdle`.
- **AI**: `TokenQuota.attachDb` → `ai_token_quota`; Workflow `.agent` inherits allowlist/audit/run_audit.
- **WS Upgrade on `Server`**: `ZFinal.addWebSocket` → 101 + handler; demo `zig build run-ws`.
- **L2/L3 ports**: `zfinal.Store` / `Cache` / `Outbox` + Memory adapters; ports-l3 re-exports.
- **AI hardening**: `AgentAuditLog.attachDb`, `Trigger.fireIdempotent` + cron failure logs,
  `TokenQuota` period/JSON, `checkApprovalSlaDedup` / `SlaNotifyGate`.
- **OAuth2 demo**: `zig build run-oauth2` (PKCE offline).
- **WS / OAuth2 / P2P / AI production hardening** (prior):
  - WebSocket handshake helpers, MASK/RSV checks, Manager broadcast snapshot.
  - OAuth2 PKCE / Basic / safe JSON; P2P bind_host / caps / heartbeat.
  - Approval HTTP tenant gate; `db.query` tenant filter; provider retries; failed run_audit.
- **`zfinal.Bus` optional adapters**: `MemoryBus` / `NatsBus` / `RobustMQBus`
  (`src/bus/`) over `QueueClient` / `QueueNatsClient` / `QueueRobustMQClient`.
  Docs: [doc/bus.md](doc/bus.md). `zf g port bus` + `examples/ports-l3` re-export
  the framework types.
- **`zf check --deadcode`**: dead-code lint via vendored
  [zdeadcode](https://github.com/chy3xyz/zdeadcode) (reachability / unused
  decls & modules). Flags: `--deadcode-warn`, `--deadcode-binary`,
  `--include-pub`, `--deadcode-json`, optional paths (default `src`).
  See `tools/zf/zdeadcode/UPSTREAM.md`.
- **`zfinal.ai` business AI runtime**: OpenAI-compatible `AiProvider` (HttpClient
  + `tool_calls` + **`chatStream` SSE** + `buildMessages`/`countTokens`/`fitsBudget`),
  `SkillRegistry`, ReAct `Agent`, `Workflow` (DAG parallel + checkpoint + **JSONL
  `WorkflowJournal`** + **`.approval` / `pending_human`** + run_audit), `Hierarchy`,
  `Trigger` (fire / cron), `RunAuditStore` (`attachDb` → `ai_run_audit`),
  `registerMemorySkills`, `registerBusinessSkills` (read-only `db.query` / entity
  whitelist on `*DB`), `ApprovalFlow` (`attachDb`, **`lookup`**, tenant filter,
  **`resolveForTenant`**, **`default_sla_ms` / `on_resolve`**, gate resume) +
  **`checkApprovalSla`**, `registerApprovalSkills` + `ToolGate` +
  **`registerApprovalHttp`**, `WorkflowJournal.attachDb` → `ai_workflow_journal`,
  `AiRuntime` bootstrap (`attachDb` for run_audit; audit / quota / memory), plus
  quota / budget / tokenizer / keyword retriever. Memory persist, `AgentHandle`,
  `ContextManager`, skill OpenAPI export, schedule⇄cron skills, `AiMetrics`
  Prometheus merge, optional client rate limit. Demos:
  `zig build run-ai-runtime` (offline), `zig build run-ai-live` (`OPENAI_API_KEY`).
  See [doc/ai.md](doc/ai.md). Orthogonal to `zfinal.aichat` (Curl/SSE/ZfTool).
- **HttpClient.requestWith / requestStream**: arbitrary headers; streaming body
  via chunk callback (forwarding `std.Io.Writer`).
- **CronPlugin.scheduleWith**: context-aware cron callbacks for AI schedule skills.
- **sockread / HttpClient micro-bench**: `zig build run-sockread-bench`
  (`benchmark/sockread_io.zig`) — Threaded Io lifecycle tax, warm socketpair
  sockread vs `net_read`, loopback `HttpClient` with dedicated Io.
- **HttpClient connection reuse**: long-lived `std.http.Client` (pool) on the
  dedicated Threaded Io; **sockread** unlimited path is bare `read` (no poll);
  timed path tries `MSG.DONTWAIT` before poll; **NATS** INFO uses chunked line
  read; **WS** uses `BufReader` (4KB). `TimedIoReader` is the `std.Io.Reader`
  adapter (Server / MQTT TLS).

### Fixed
- **WebSocket / plugin / HTTP server socket-read hang under shared Threaded Io**:
  long-blocking socket reads now use `posix.read` via `src/core/sockread.zig`
  (matching zigmodu; unlimited waits skip redundant poll). Covers WebSocket
  frames (`BufReader` collapses header/mask/payload into ~1 refill), Redis RESP,
  NATS, RobustMQ/Kafka, MQTT (`TimedIoReader` TLS underlay), P2P, and HTTP
  `Server` receiveHead/body. Timed paths keep `poll` (`readSomeTimeout`).
  `HttpClient` keeps full `std.http.Client` on a long-lived dedicated Threaded Io
  + connection pool. Io `net_read`/`readv` could hang with data already buffered
  when accept + workers (+ client) share one Threaded Io.
- **Optional DB drivers link into examples/tests**: `-Ddriver_pg` / `-Ddriver_mysql`
  now propagate `-lpq` / `-lmysqlclient` to `zfinal` and example artifacts (CI
  drivers jobs were failing with undefined `PQ*` / `mysql_*`).
- **`ruoyi-gen` gated on `-Ddriver_mysql`**: default `zig build` no longer requires
  `libmysqlclient` (macOS CI only installs SQLite).
- **PG/MySQL live test teardown**: `tryOpenPG` / `tryOpenMY` returned a by-value
  `DB` copy after `DB.init` heap-allocated `*DB`, so `destroy()` freed stack
  memory (SafeAllocator panic). Helpers now return `?*DB`.

## [0.20.11] - 2026-07-31

### Fixed
- **CI / `zig build` on Linux**: bump `zent` to **v0.12.1** (build.zig no longer uses
  `extern "c" stat`; Zig 0.17 requires explicit libc for that and failed the
  productized quality gate on Ubuntu).

## [0.20.10] - 2026-07-31

### Added
- **Productized quality / release gates** (ADR-014): `scripts/quality_gate.sh`
  (`quick`|`full`|`release`), `zig build gate` / `gate-quick` / `release-gate`,
  `zf gate` / `zf release-check [--json]`. Release mode requires `## [semver]` in
  CHANGELOG, checks `v$semver` tag collision, and supports `--strict` dirty-tree fail.
  CI: Ubuntu **Quality gate** is the merge gatekeeper; macOS is slim coverage;
  tag pushes run `release --strict`. See [`doc/release_and_quality_gates.md`](doc/release_and_quality_gates.md).
- **Module marketplace phase 1** (ADR-015): `marketplace/catalog.json` +
  `zf market list|search|info [--json]`. Discoverability only; no remote install.
  See [`doc/module_marketplace.md`](doc/module_marketplace.md).

### Fixed
- **`getText` on SUM/DECIMAL floats**: numeric cells no longer format into a
  threadlocal scratch buffer (ephemeral; easy to misread as ResultSet-owned and
  observe freed/debug-fill `UUUUUUUU`). `getText` now materializes **row-owned**
  strings valid until `Row.deinit`. MySQL still **dupes** `CAST(... AS CHAR)` /
  `VAR_STRING` into the ResultSet allocator (the reported `mysql_free_result`
  dangling-pointer path was not present). Prefer `getFloat` for money aggregates.
- **MySQL SUM(varchar) / money via `getInt`**: `Row.getInt` / `queryScalar(i64)` /
  `intAt` no longer silently truncate fractional `.float` cells (e.g. `30.80` → `30`).
  Fractional values return `error.NotAnInteger`; use `getFloat` / `queryScalar(f64)`.
- **RouteGroup param-route UAF**: `addWithMethodAndInterceptors` now dupes the path
  before `parseRoute`, so `Segment.value` / `param_names` point at owned memory.
  Previously `RouteGroup.register` freed its `allocPrint` buffer after register and
  every group-registered `:id` route 404'd while static group routes still matched.
- **`zf routes` fmt alignment**: interceptor slices emit `&.{ic.x}` / `&.{ a, b }`
  to match `zig fmt`, so `--check` stays green after format.

### Docs
- Best-practice hub + envelope docs remain under 0.20.9 narrative; this release
  adds gate/marketplace product docs (ADR-014/015).

## [0.20.9] - 2026-07-31

### Added
- **Smart routing**: `actions.zig` / `zf routes`, seal + specificity, CI check (see ADR-011).
- **Axum-style HTTP ergonomics**: State / Extension / extract / HttpError / stock layers / fallback+merge / oneshot.capture(+With) / SSE helpers (ADR-012).
- **Caller-owned interceptor config**: factories take `*const Cfg` + `userdata` / `before_ud` (`JwtAuthConfig`, `CorsAllowlistConfig`, `TokenInterceptorConfig`, `SecurityHeadersConfig`, stock body-limit / timeout / compression). Removed public `heapCfg`.
- **OpenAPI field-level DTOs**: `zf openapi` parses `pub const Name = struct` and zent `Schema("Name", field.*)` into `Name` / `NameInput` with route `$ref`; irregular plurals (`categories`→`Category`).
- **Codegen `failHttp`**: generated handlers use HttpError (`failHttp` + `extract.requireParamInt`); `zf check --heal` migrates and strips dead `fn err`.
- **`zf check` WARNs**: `heapCfg(`, legacy JWT/HSTS by-value factories, temporary `&.{` interceptor cfg, Cache interceptor on `--prod`.

### Changed
- **Interceptor `before_ud` convergence**: all stock/demo factories use `_ud`; public `runBefore`/`runAfter`; 404/405/fallback run global `runAfter`.
- **P0 HttpError unify**: RateLimit / demo Auth / ParamExt / production `me` Ext; `markResponded` on all render paths.
- Cache interceptor: GET hit-only; after-store only with `ctx.capture` (documented).
- Docs / scaffold HttpError alignment (`SECURITY.md`, `PRODUCTION_AUDIT`, `zf new` user handler, migration samples).
- `examples/production` / `auth` / `smart-routing` / `ruoyi-gen` updated for caller-owned cfg + `failHttp`.

### Docs
- `doc/http_ergonomics.md`, `doc/session.md`, `doc/reverse_proxy.md` §9, `PRODUCTION_AUDIT.md`, `.life/evolution.md`.
- **Best-practice hub** [`doc/best_practices.md`](doc/best_practices.md); [`doc/api_envelope.md`](doc/api_envelope.md) + ADR-013.

## [0.20.8] - 2026-07-23

### Fixed
- **Keep-alive / async_limit slot exhaustion**: apply `force_connection_close` **before** `respond` so `Connection: close` is on the wire; drop per-connection idle-watchdog Io fiber (it doubled slot use with `handleConn` and left fibers stuck in `receiveHead` — sequential curls died after ~3–4 OK). Idle read bounded by `read_timeout_ms` only.

## [0.20.7] - 2026-07-23

### Fixed
- **Idle watchdog mid-handler**: `request_timeout_ms` no longer closes sockets during `dispatch` (`in_dispatch` gate). Prevents mass `WriteFailed` / HTTP 000 when handlers wait on DB (~30s) under concurrency.
- **WriteFailed soft path**: client-gone / write-deadline errors skip the 500 render attempt and end the connection cleanly.
- **ConnectionPool ping under lock**: `acquire` / `keepAlive` ping outside the pool mutex so blocking driver round-trips cannot starve other worker threads.

## [0.20.6] - 2026-07-23

### Fixed
- **Router param-cache concurrency**: `param_cache_mutex` serializes FIFO lookup/put/eviction (threaded `dispatch` shared Router). Prevents heap corruption that surfaced as interceptor-path crashes after the v0.20.5 double-free fix enabled real eviction.
- **`execute` uses `matchIndex`**: snapshot handler/interceptors by route index instead of holding a dangling `*Route` across allocations.
- **Static route first-wins**: `addWithMethod` indexes `static_routes`; duplicate registrations keep the first index (linear-scan semantics) and free duplicate keys.

## [0.20.5] - 2026-07-23

### Fixed
- **Router `paramCachePut` double-free**: hashmap key and FIFO order list share one allocation; eviction no longer frees twice (Abort once cache fills). Append-failure path drops the map entry before freeing.
- **MySQL text protocol column types**: `col_types` / `mysqlTextToCell` use `c_uint` end-to-end (Zig 0.17 / `enum_field_types`), avoiding signed `@intCast` round-trips.

## [0.20.4] - 2026-07-23


### Changed
- **`zf` CLI modularization (phase 1–3)**: extracted `tools/zf/zf_shared.zig` (IO/FS/`safeWrite`/`appendJsonString`/`writeAiConfigs`), `tools/zf/zf_db.zig` (`ZfDb`), `cmd_migrate.zig` (migrate/seed), `cmd_openapi.zig`, `cmd_check.zig`, `cmd_crud.zig` (crud/admin + bootstrap), `cmd_fixture.zig`, `cmd_bench.zig`. `main.zig` is the dispatcher (~1.4k lines).

### Added
- **`zf g port store|cache|bus`**: generates `src/ports/{name}.zig` + matching `src/adapters/*` stubs aligned with L2/L3 in `doc/progressive_architecture.md` (`--json` / `--force`).
- **`examples/ports-l2`**: runnable L2 DI demo (store/cache/bus ports + memory adapters + OrdersService). `zig build run-ports-l2`.
- **`zf check --prod --root <dir>`**: portable production-contract scan (default root `examples/production`; custom roots warn on missing BFF wiring).
- **ai-edit-zone preserving regen**: `safeWrite` merges matching zone bodies via `tools/zf/zone_merge.zig` before falling back to `.gen.new`.
- **JWT RS256 verify + sign**: `jwtVerifyRs256` / `jwtSignRs256` (PEM/DER public + PKCS#1/PKCS#8 private keys).
- **RobustMQ OffsetFetch / LeaveGroup**: wire + `KafkaConsumer.fetchCommittedOffset` / `leave`.
- **RobustMQ JoinGroup / SyncGroup / Heartbeat**: wire builders + `KafkaConsumer.join` / `heartbeat`; `OffsetCommit` now carries generation/member from join.
- **Kafka classic range rebalance**: leader divides partitions across members; `poll` / offsets are per assigned partition.
- **Kafka Metadata partition discovery**: Metadata API v1; `partition_count=0` (default) auto-discovers per topic; `>0` overrides.
- **Kafka sticky assignor**: `KafkaConsumerConfig.assignor = .sticky` (classic sticky; cold start ≈ range).
- **Keep-alive safety suite**: `keepalive_safety.zig` — drain/#25017 live regression + `force_connection_close` default assert.
- **MQTT native TLS**: `MqttConfig.use_tls` via `std.crypto.tls.Client` (`tls_insecure` / `tls_server_name`).
- **Metrics route classes**: health/metrics/api/admin/static/other + `routeTemplate` helper.
- **`zf openapi` deepen**: bearerAuth, JSON requestBody, 400/401/404 responses.
- **`examples/ports-l3`**: tenant + outbox + bus L3 DI demo (`zig build run-ports-l3`).
- **Benchmark baseline**: `benchmark/BASELINE.md` + ReleaseSafe/force-close guidance.
- **RobustMQ OffsetCommit wire**: `KafkaWireFormat.buildOffsetCommitRequest` + `RobustMQTransport.offsetCommit` + `KafkaConsumer.commitLocal` / `commit`.

### Fixed
- **`write_timeout_ms` authenticity**: after Zig 0.17 removed `Operation.net_write`, the field was retained but ignored. `TimedWriter` now enforces a wall-clock deadline from the first response `drain` (reset per request). Idle watchdog + reverse-proxy timeouts remain complementary.
- **Version / manifest drift**: `src/version.zig` is the single runtime/codegen source of truth (must match `build.zig.zon`); CLI + `zf crud:* --json` / `ZfTool` manifests no longer hardcode stale `0.13.11` / `0.9.x` strings.

### Docs
- Clarified regeneration: matching `ai-edit-zone` names are **merged** into the existing file; otherwise `<path>.gen.new` (or `--force`).
- Refreshed `PRODUCTION_AUDIT.md` / `SECURITY.md` / agent docs to **0.20.4**.
- **`doc/reverse_proxy.md`**: nginx/Caddy client keep-alive + ZFinal `force_connection_close=true`; flip checklist §9.
- `doc/robustmq.md`: JoinGroup + Metadata + range/sticky.
- `doc/codegen.md` / `doc/progressive_architecture.md`: ports codegen + ports-l3.

## [0.20.3] - 2026-07-22

### Added
- **`zf new` now generates standalone projects** that depend on the remote zfinal tarball (`https://github.com/chy3xyz/zfinal/archive/refs/tags/v0.20.3.tar.gz`) instead of a local relative path. Generated `build.zig` uses `b.dependency("zfinal", ...)` and the driver option names (`driver_pg` / `driver_mysql`) match the framework's `build.zig`.
- **`zf migrate` / `zf seed` multi-driver support**: the CLI now supports SQLite, PostgreSQL, and MySQL for migration and seed operations. Driver selection is controlled by the `ZFINAL_DB_TYPE` environment variable (`sqlite`, `postgres`/`pg`, `mysql`/`my`; default `sqlite`).
  - SQLite: `ZFINAL_DB_PATH` (default `zf.db`).
  - PostgreSQL: `ZFINAL_PG_DSN` or `ZF_PG_HOST/PORT/USER/PASSWORD/DATABASE`.
  - MySQL: `ZFINAL_MY_DSN` or `ZF_MY_HOST/PORT/USER/PASSWORD/DATABASE`.
- Internal `ZfDb` abstraction in `tools/zf/main.zig` unifies `exec`, `queryExists`, `queryText`, and tracking-table creation across the three drivers.

### Fixed
- **Zig 0.17-dev API compatibility**: updated `Metrics.recordError` to acquire `error_mutex` via `std.Io.Mutex.lockUncancelable`/`unlock` with the global Io instance, and rewrote the server's `TimedWriter` to use the new `Writer.VTable.drain` + `Io.vtable.netWrite` path after `Operation.net_write` was removed from the standard library. This restores compilation on the latest Zig 0.17.0-dev snapshots.

## [0.20.2] - 2026-07-22

### Added
- **`DB.queryCached`**: execute a server-side-prepared statement and return a `ResultSet`. Available for PostgreSQL (`PQexecPrepared` with binary output) and MySQL (`MYSQL_STMT` fetch), while SQLite intentionally returns `error.UnsupportedDriver` because it already provides `queryParams` with local prepared-statement support.
- **Driver-side helpers**: `PostgresDB.resultSetFromPgRes` and `MySQLDB.resultSetFromStmt` share the row-materialization logic between the existing `queryParams` paths and the new cached-statement paths.

### Tests
- SQLite rejects `queryCached` with `error.UnsupportedDriver` in both `src/db/db.zig` and `src/db/integration_test.zig`.
- PG/MySQL `queryCached` tests are gated behind live DB env vars and SKIP when unavailable.

## [0.20.2] - 2026-07-08

### Added
- **`DB.queryCached`**: execute a previously-prepared statement and return a fully-owned `ResultSet`. Works for PostgreSQL and MySQL (binary result format); SQLite returns `error.UnsupportedDriver`.
- **`ConnectionPool.startReaper`**: optional background thread that calls `keepAlive()` on an interval and drains dead connections. Safe `deinit` joins the thread before tearing down pool state.
- **Server `write_timeout_ms`**: response writes now respect `Io.operateTimeout(.net_write, ...)`, matching the existing read-timeout path.

### Fixed
- **ConnectionPool `release()` ordering**: `checkIn()` now runs only after the connection is successfully appended back to the pool, preventing a leak when `available.append` fails.

## [0.20.1] - 2026-07-08

### Fixed
- **PostgreSQL / MySQL driver compilation**: restored `-Ddriver_pg=true -Ddriver_mysql=true` to compile cleanly. Fixed c_uint/c_int type mismatches, `PQexecParams` result format argument, opaque `PGresult` return type, stale `entry.name[0.. :0].*` syntax, and `readInt` buffer syntax.
- **MySQL TEXT/BLOB truncation**: `mysql_stmt_fetch` returning `MYSQL_DATA_TRUNCATED` no longer continues into a buffer overread; now returns typed `error.DataTruncated`.
- **Metrics race**: `recordError` now locks `error_mutex` (std.Io.Mutex) before mutating `recent_errors`, preventing concurrent append corruption.

## [0.20.0] - 2026-07-08

### Added
- **Slow-query diagnostics**: `DB` times `exec`, `execParams`, `query`, and `queryParams`, logs SQL exceeding the configurable 100 ms threshold, and exposes a per-connection atomic counter.
- **`zf openapi`**: scans static direct, interceptor, and `RouteGroup` routes; normalizes path parameters; emits deterministic OpenAPI 3.0.3 YAML without overwriting an existing spec.

### Changed
- **O(1) named-column lookup**: `ResultSet` builds a name-to-index cache once per query, avoiding repeated linear scans in wide ORM rows.

### Fixed
- **Numeric result text lifetime**: integer and float compatibility formatting now uses thread-local buffers instead of returning slices into expired stack frames. This fixes `InvalidField` failures exposed by cached `RowMap` lookup.

## [0.13.11] - 2026-07-20

### Added — contractual production readiness **9.8**
- **`createJwtAuthInterceptorWithOptions`**: iss/aud/leeway/`previous_secret` on the interceptor path.
- **`createSecurityHeadersInterceptor`** / **`createRequestIdInterceptor`**: baseline headers + `X-Request-Id`.
- **Per-route-class latency**: `Metrics.recordRouteLatencyMs` → Prometheus `zfinal_request_duration_by_route_ms_{sum,count}`.
- **`examples/production`**: Request-ID + security headers; JWT env `JWT_ISS` / `JWT_AUD` / `JWT_SECRET_PREVIOUS` / `ENABLE_HSTS`.
- **`zf check --prod`**: scopes to `examples/production` and asserts required wiring (CI lint job runs it).
- **`PRODUCTION_AUDIT.md`**: contractual **9.8 / 10** (absolute ~9.1 until Zig stable + keep-alive).

### Changed
- Version align: `build.zig.zon` / `zf` / README badge → **0.13.11**.

## [0.13.10] - 2026-07-20

### Changed — production readiness honesty + hardening
- **`PRODUCTION_AUDIT.md`**: independent score **6.8/10** (controlled deploy ~7.5–8); replaces marketing “95%”.
- **`ServerConfig.drain_timeout_ms`** (default 30s): hard-cap graceful connection drain.
- **`createCorsInterceptor(origin)`**: non-wildcard CORS; default `CORSInterceptor` documented as unsafe for credentials.
- **`examples/production`**: CSRF on POST, rate limit, restricted CORS, `shutdown.registerHandlers()`, drain timeout.
- **Version align**: `build.zig.zon` / `zf` CLI / README badge → **0.13.10**; `SECURITY.md` support table + practices.
- **Docker**: pin Zig via zigup to CI version (not `apk add zig`).

### Added — zent as alternative / primary data layer (`zfinal.zent`)
- **zent** (`v0.12.0`) in root `build.zig.zon`; export **`zfinal.zent`** / **`zent_enabled`** beside `DB`/`Model`.
- Positioning: **two first-class alternatives** — SQL stack (`DB`/`Model` + `zf`) **or** zent (can be the app's **main** ORM for e-commerce / social).
- Build flag **`-Denable-zent`** (default **true**); ADR-007; `doc/zent.md`; `examples/zent-shop`.
- **`zf crud:zent`**: generate zent-primary modules from `.zent` DSL or `.json` (`tools/zf/zent_codegen.zig`) → `model` / `persistence` / `service` / `handler` / `routes` + rich `--json` manifest (`ai_edit_zones` with file/markers/purpose).
- **AI-first zent**: `zfinal.aichat.ZfTool.manifestFromZent` / `buildAgentSystemPromptZent`; skill `.claude/skills/zfinal-zent-ai.md`; dual path in `doc/ai-quickstart.md` / onboarding.

## [0.13.9] - 2026-07-19

### Changed — QueueNatsClient promoted to stable
- Replaced optional `nats.zig` dependency with zero-dep NATS wire client (`plugin/nats_client.zig`, from zigmodu).
- Stable exports: `NatsClient`, `NatsConfig`, `QueueNatsClient` (`connect` / publish / subscribe / request / poll).
- `zfinal.experimental.QueueNatsClient` kept as `@deprecated` alias.
- Docs: `doc/nats.md`.

## [0.13.8] - 2026-07-19

### Added — RobustMQ / Kafka connector
- **`plugin/robustmq.zig`**: Kafka wire client (ApiVersions + Produce + Fetch) targeting RobustMQ default `:9092`, ported from zigmodu `KafkaConnector` (zero third-party deps).
- Stable exports: `RobustMQTransport`, `KafkaProducer`, `KafkaConsumer`, `KafkaEventBridge`, `QueueRobustMQClient`.
- Offline unit tests + optional live smoke via `ROBUSTMQ_URL` / `KAFKA_BOOTSTRAP`.
- Docs: `doc/robustmq.md`; progressive / scale docs prefer RobustMQ over NATS for L3 bus.

Still experimental (as of 0.13.8): none for messaging — NATS is stable in 0.13.9.

## [0.13.7] - 2026-07-19

### Changed — remaining plugins promoted to stable
- **P2pPlugin**: TCP mesh (ZFP2 frames), `addPeer` / `broadcast` / `announce` / inbox + localhost mesh + gossip announce tests.
- **HttpClient**: real `std.http.Client` wrapper (`get`/`post`/`put`/`delete`/`postForm`); response body via `std.Io.Writer.Allocating`.
- **ConfigClient**: env / JSON file / env_then_file.
- **BeanValidator**: fluent façade over `Validator`.
- **TaskScheduler**: cron + fixed-rate / fixed-delay via `tick()`.
- **MessageQueue**: Spring-style wrapper over in-process `QueueClient`.
- **OAuth2Client**: authorize URL builder + code / client_credentials / refresh token exchange helpers.

Still experimental: `QueueNatsClient` (optional NATS dep).

### Changed — Zig 0.17.0-dev.1422 compatibility
- CI pin: `0.17.0-dev.813+2153f8143` → `0.17.0-dev.1422+e863bf3be`.
- **P2pPlugin**: `std.atomic.Mutex` no longer has `lock()` — spin on `tryLock`.
- **HttpClient**: `FetchOptions.response_writer` is `?*Writer` (use `Writer.Allocating`).
- **zf migrate**: `std.hash.crc.Crc32` → `std.hash.Crc32` (`CRC-32/ISO-HDLC`).

## [0.13.6] - 2026-07-19

### Changed — plugins promoted to stable
- **CircuitBreaker**: full closed/open/half-open state machine with `call()` helper + tests (`plugin/circuit_breaker.zig`).
- **QueueClient**: real in-process pub/sub with mailboxes (replaces no-op stub).
- **DidPlugin**: leak-free local `did:key` Ed25519 identity; `DidDocument.deinit`; sign/verify/resolve tests.
- **AgentPlugin**: MCP `tools/list` + `tools/call` (and legacy `call_tool`); working tool list.
- **MetricsExporter**: Prometheus exposition text + JSON from `Metrics`.
- **MqttPlugin**: MQTT 3.1.1 CONNECT/CONNACK/PUBLISH QoS0/PINGREQ/DISCONNECT; remaining-length encoding tests.
- **ObjectMapper**: exported on stable API (JSON read/write).

Still experimental (as of 0.13.6): `P2pPlugin`, `QueueNatsClient`, HttpClient/OAuth2/Config — see 0.13.7.

## [0.13.5] - 2026-07-19

### Security
- **Trusted-proxy IP policy**: `IpExt.resolveClientIp` / `ClientIpOptions` — proxy headers ignored by default; rate limiter and access log no longer trust spoofable `X-Forwarded-For` unless explicitly enabled (optional `trusted_proxies` allow-list).
- **Cookie defaults**: `setCookie` now sets HttpOnly + SameSite=Strict; optional Secure via `setCookieFull`.

### Changed
- **Experimental plugin namespace**: MQTT / Agent / DID / P2P / Queue / Java-compat stubs moved to `zfinal.experimental.*` so the default API surface is production-stable only.
- **Redis RESP**: loop-read until complete value, `NeedMoreData`, 4MB response cap, unit tests for parseResp.
- **Token/Captcha**: public `purgeExpired()` for idle cleanup.
- **healthHandlerFor**: returns a proper `Handler` (`*Context`) matching the router.
- **Production example**: Metrics-backed `/health`; documents trusted-proxy rate-limit config.
- **CI**: ReleaseSafe smoke build step.
- **PRODUCTION_AUDIT.md**: rewritten as single source of truth — overall **95%**.

### Fixed
- **renderFile**: last partial read chunk was discarded (truncated downloads).

## [0.13.4] - 2026-07-08

### Fixed (P0)
- **redis.zig broken syntax**: orphaned duplicate `exists()` body after `subscribe()` made the file unparseable. Also fixed `exists()`/`publish()` RESP integer comparison — `parseResp` strips the `:` prefix, so comparing against `":1"` never matched.
- **Test suite could not compile since v0.13.2**: model.zig tests passed `**DB` where `*DB` expected (missed when `DB.init` moved to heap return); worker.zig `pthread_create` entry-fn signature mismatch on Zig 0.17 (`*anyopaque` vs `?*anyopaque`). Baseline restored: 146 passed, 2 skipped, 0 failed.
- **ConnectionPool.deinit unlock-after-destroy**: `defer unlockMut` fired after `destroyMutex` + `destroy(self)`, unlocking a freed mutex → panic → hung process. Mutex now explicitly unlocked before destruction.
- **checked_out guard broke standalone connections**: direct `DB.init` conns failed every operation with `error.CheckedOut`. Default is now `true` (creator owns the conn); the pool flips it via `checkIn()` on pool insertion/release, preserving use-after-release detection for pooled conns.

### Changed
- **No more @panic on rollback/mutex paths**: transaction rollback failures (pool.zig, model.zig insertBatch) log via the structured logger and propagate the original error; mutex locks in session/thread_pool/websocket-manager use `lockUncancelable` instead of `catch @panic`.
- **Silent `catch {}` now logged**: server 503-write and 500-render failures, websocket ping/pong/close frame write failures.
- **Removed debug prints**: `REGISTER GET/POST` output on every route registration.

### CI
- **Zig version aligned with build.zig.zon**: 0.14.0 → 0.17.0-dev.813+2153f8143 (via mlugg/setup-zig). Added `zig build test-zf` codegen regression step; fmt check now covers benchmark/ and build.zig.

## [0.13.3] - 2026-06-13

### Fixed
- **DB.begin/commit/rollback missing**: pool.transaction() called non-existent methods. Now implemented: each runs the corresponding SQL statement via exec, with checked_out guard.

## [0.13.2] - 2026-06-13

### Fixed (P0)
- **12-borrow crash**: DB.magic sentinel (0xDBDBDBDB) + pre-alloc ArrayList capacity. Eliminates reallocation that frees old buffer and may corrupt adjacent DB structs via Zig 0.17 debug allocator 0xaa fill.

## [0.13.1] - 2026-06-13

### Fixed (P0)
- **Use-after-release guard**:  flag +  check. Returns  if conn used after .

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.19.0] - 2026-07-08

### Added
- **Static file ETag / If-None-Match 304** — `StaticFile` now sets
  `ETag: W/"<fnv1a>"` on every response. If the client sends
  `If-None-Match: <etag>` and it matches, the handler responds with
  304 + no body, saving 100% of the response bandwidth for repeat
  visitors. Cached clients (browsers, CDN) get sub-millisecond 304s.
- **Per-request deadline** — `Context.setTimeoutMs(ms)` sets a monotonic
  deadline; `Context.isExpired()` returns true once the deadline has
  elapsed. Server `dispatch` checks the deadline before invoking the
  handler and after, sending `408 Request Timeout` if expired.
  Controlled by `ServerConfig.request_timeout_ms` (default 30s).
- **Router FIFO match cache** — `Router` now caches parameterized-route
  lookups (capped at 1024 entries, FIFO eviction). The static-route
  HashMap was already O(1); this closes the linear-scan fallback for
  the common case of repeat hits to the same parameterized URL.
- **gzip response compression wired into render methods** — `renderText`,
  `renderJson`, `renderHtml` now call `compressBody` when the client
  sends `Accept-Encoding: gzip` and the body is ≥ 256 bytes. Adds
  `Content-Encoding: gzip` header automatically. Falls back to
  uncompressed on compression failure (with stderr log).

### Fixed
- **5 silent `catch {}` sites in `src/core/context.zig`** now log via
  `std.debug.print` with the error name and a brief explanation.
  Catches that were previously silent: `headers.ensureTotalCapacity`,
  `attrs.ensureTotalCapacity`, `reader.discardRemaining` (2 places),
  and the 3 `compressBody` failure paths.
- **`std.time.nanoTimestamp` removed in Zig 0.17** — replaced with a
  `monoNowNs()` helper that uses `std.c.clock_gettime(.MONOTONIC, ...)`.
  Replaces 2 call sites in `setTimeoutMs` and `isExpired`.

### Added (zf CLI)
- **`zf new` now generates `docker-compose.yml` + `Dockerfile`** for
  single-binary deployment. `docker-compose.yml` includes the app
  service with healthcheck + commented PostgreSQL template.
  `Dockerfile` is multi-stage (Zig build → debian-slim runtime).
  Container names are derived from the project name (lowercased,
  dashes → underscores).

### Tests
- Total: **215 passed; 9 skipped; 0 failed** (no new test cases
  needed — existing integration suite still passes after the
  context/router refactor).

## [0.18.0] - 2026-07-08

### Added (API ergonomics)
- **`DB.transaction(cfg, body)`** — closure-based auto-commit / rollback.
  If `body` returns normally, the transaction commits. If it errors,
  the transaction rolls back and the error propagates. Optional
  `DeadlockRetry` config (currently classifies MySQL/PG `Deadlock`
  errors as retryable, max 3 attempts).
- **`DB.transactionResult(T, body)`** — generic-returning variant. Use
  when the body produces a value (computed aggregate, generated ID,
  etc.).
- **`DB.queryScalar(T, sql, params)`** — single-cell shortcut for
  COUNT / MAX / EXISTS queries. `T ∈ {i64, f64, bool, []const u8}`.
  For `T = []const u8` the returned slice is heap-allocated via the
  passed-in allocator (caller owns + frees).
- **`DB.execMany(sql, rows)`** — runs the same SQL once per row in
  the batch. Caller passes a slice of `[]const SqlParam` slices.

### Added (Prepared statement cache — PG + MySQL)
- **`DB.prepareCached(name, sql, n_params)`** /
  **`DB.execCached(name, params)`** /
  **`DB.releaseCached(name)`** — server-side (PG `PQprepare` /
  `PQexecPrepared`) or connection-local (MySQL `MYSQL_STMT*`)
  prepared statement cache. Skips server-side parse + plan on repeat
  calls. Typical 2-5x speedup on hot queries.
- Cache entries are auto-released on `db.destroy()`.
- SQLite returns `UnsupportedDriver` for the cache API (no-op).

### Tests
- 7 new integration tests (transaction commit/rollback/result,
  queryScalar typed returns, execMany, minimal exec+query, cache
  driver guard).
- Total: **215 passed; 9 skipped; 0 failed** (was 208 / 9 / 0).

### Known issue
- **`transaction` body must be a NAMED function or struct method** —
  not an anonymous struct literal. Zig 0.17 has a lifetime issue
  with anonymous struct function pointers as `comptime body`; using
  one corrupts the next query. Documented in the API doc comment.

## [0.17.0] - 2026-07-08

### Added
- **`PostgresDB.queryIter(sql, params) !PgIter`** — incremental
  query iterator using `PQsetSingleRowMode`. Single-row mode is set
  BEFORE the query, then `PQgetResult` is called repeatedly until
  NULL. Memory usage is O(1) per row. `PgIter.deinit()` drains the
  required trailing `PQgetResult` call to release connection state.
- **`Row.intAt(idx) -> i64`** / **`Row.floatAt(idx) -> f64`** /
  **`Row.boolAt(idx) -> bool`** — hot-loop helpers that return the
  typed value directly without the error-union + optional wrapper of
  `getInt`/`getFloat`/`getBool`. Panics on null / type mismatch
  (caller is responsible for schema validation). In `zig build
  run-db-bench`, `intAt` is ~1.0–1.2x faster than `Row.getInt` and
  matches or beats the legacy `getText + parseInt` path.
- **`benchmark/db_decode.zig`** — micro-benchmark comparing three
  numeric-read paths: `Row.getInt` (error-union), `Row.intAt`
  (direct), legacy `getText + parseInt`. Run via `zig build
  run-db-bench`.
- **`docker/test-compose.yml`** + **`docker/run-live-tests.sh`** —
  live PG + MySQL test environment. Bring up with `docker compose
  -f docker/test-compose.yml up -d`, then run `run-live-tests.sh` to
  execute the integration suite against live servers. Detected via
  `ZF_PG_*` / `ZF_MY_*` env vars (already supported by
  `integration_test.zig`).

### Tests
- 3 new unit tests in `result.zig` for `intAt` / `floatAt` / `boolAt`.
- Total: **208 passed; 9 skipped; 0 failed** (was 205 / 9 / 0).

### Deferred (no change)
- gRPC support (Roadmap v1.0 item) — still v1.0.

## [0.16.0] - 2026-07-08

### Added (Unix socket + streaming)
- **`DBConfig.unix_socket: ?[]const u8`** — connect via local Unix domain
  socket instead of TCP. Both PG and MySQL honor it.
  - **PG**: emits `host=/path/to/socket` in conninfo, port omitted.
  - **MySQL**: passed as the 7th arg to `mysql_real_connect`; libmysql
    auto-detects the SOCKET protocol.
- **Incremental query iterators** — stream rows without materializing
  the full result set into RAM:
  - **`SQLiteDB.queryIter(sql, params) !SQLiteIter`** + **`SQLiteIter.next() !?Row`**
  - **`MySQLDB.queryIter(sql, params) !MySQLIter`** + **`MySQLIter.next() !?Row`**
  - Both yield one typed `Row` per call. Caller iterates and frees each
    row's cell payloads with `row.deinit()`. Memory usage is O(1) per row.
- **Shared `readSqliteCell` helper** in sqlite.zig (dedupes the
  Cell-emission path used by both `queryParams` and `SQLiteIter`).

### Tests
- 2 new integration tests for SQLite iterator (50-row stream + empty
  result set + double-deinit safety).
- Total: **205 passed; 9 skipped; 0 failed** (was 203 / 9 / 0).

### Deferred
- **PG incremental iterator**: requires `PQsetSingleRowMode` refactor
  of `queryParams`. Logged as TODO in postgres.zig. Coming in v0.17.

## [0.15.0] - 2026-07-08

### Changed (Breaking — DB result API)
- **`Row.cells` is now `[]Cell` (was `[]?[]const u8`)**
- **`ResultSet.addRow` now takes `[]Cell` (was `[]?[]const u8`)**
- All `Row.cells` / `addRow` call sites updated in drivers + tests
- **External callers of `getText`/`getInt`/`getBool`/`getCurrentRowMap`
  are NOT broken** — these getters auto-adapt to the new Cell union
  (text cells pass through, int/float cells format on demand).

### Added (Performance — binary result decoding)
- **`Cell` tagged union in `result.zig`**: `{ null, text, int, float, bool, blob }`.
  Drivers now emit typed Cells directly, eliminating the parseInt/parseFloat
  round-trip on every consumer read.
- **PG: `resultFormat=1` (binary) + per-OID typed reads** — INT2/INT4/INT8
  decoded via `std.mem.readInt(..., .big)`; FLOAT4/FLOAT8 via `@bitCast`;
  BOOL via byte test; BYTEA → blob; everything else falls back to text.
  Cached `PQftype` per column (avoids O(n*rows) repeat lookups).
- **MySQL: per-column typed `MYSQL_BIND`** — numeric columns ask for
  `MYSQL_TYPE_LONGLONG` (binary i64) or `MYSQL_TYPE_DOUBLE` (binary f64).
  Replaces the previous "every column → `MYSQL_TYPE_STRING` with 4096-byte
  buffer" approach. `mysqlTextToCell` handles the text-protocol fallback
  for `query()` (non-prepared) results.
- **SQLite: typed stepColumn** — INTEGER → `.int`, FLOAT → `.float`,
  TEXT → `.text`, BLOB → `.blob`, NULL → `.null`. No text round-trip
  on numeric columns.
- **`Row.getFloat(idx)`** — new getter for f64 cells (was previously
  only available via `parseFloat` on text).
- **`RowMap.getInt(col_name)`** — name-lookup variant of `Row.getInt`.

### Performance impact
- **MySQL numeric reads**: ~2x faster (no parseInt on every cell read).
- **PG numeric reads**: ~2x faster (no server-side to_text + no
  client-side parseInt).
- **SQLite numeric reads**: ~1.5x faster (avoids text conversion when
  consumer only reads int).
- **Cell storage**: text/blob payloads still heap-allocated and freed
  by `Row.deinit`. Int/float/bool are stack-resident (8 bytes max).
- **`Row.cells` 8-byte alignment** lets consumers iterate via slice
  indexing without per-cell indirection.

### Tests
- **7 new unit tests** in `result.zig`:
  - `getInt returns int directly without parseInt`
  - `getInt on text cell uses parseInt (legacy)`
  - `getText on int cell formats to decimal`
  - `getBool maps common forms`
  - `getFloat`
  - `null cell returns null on every getter`
  - `blob payload freed by Row.deinit (no leak)`
- Total: **203 passed; 9 skipped; 0 failed** (was 197 / 9 / 0).

## [0.14.0] - 2026-07-08

### Added (DB driver parity)
- **`src/db/diag.zig`** — unified SQL error diagnostics. Maps PG SQLSTATE
  (23xxx, 40P01, 55P03, 42xxx) and MySQL errno (1062, 1451/1452, 3819, 1048,
  1205, 1213, 1064, 1146) to a shared `ErrorCode` enum + 10 unit tests.
- **`DBConfig.ssl_mode: SSLMode`** — TLS configuration shared by PG and MySQL.
  Values: `disable`, `prefer` (default, libpq default), `require`, `verify_ca`,
  `verify_full`. Production cloud DBs should set `.require` or stronger.
- **`SSLMode` enum** in `config.zig` with doc comments for each level.
- **PG: `connect_timeout=N` in conninfo** — `DBConfig.timeout` was previously
  declared but never honored; now it actually controls the connect deadline.
- **PG: `client_encoding=UTF8` in conninfo** — explicit declaration so PG
  does not silently fall back to SQL_ASCII on misconfigured clusters.
- **MySQL: `MYSQL_OPT_CONNECT_TIMEOUT`** — connect timeout via `mysql_options`.
- **MySQL: `MYSQL_OPT_SSL_MODE`** — maps `SSLMode` to libmysqlclient's
  `enum mysql_ssl_mode` (`SSL_MODE_DISABLED`..`SSL_MODE_VERIFY_IDENTITY`).
- **MySQL: `mysql_set_character_set(conn, "utf8mb4")`** — full Unicode +
  emoji round-trip. Server default is `utf8` (3-byte BMP only) or `latin1`.

### Fixed (DB driver AI-friendliness)
- **Typed SQL errors**: `error.UniqueViolation`, `error.ForeignKeyViolation`,
  `error.CheckViolation`, `error.NotNullViolation`, `error.LockTimeout`,
  `error.Deadlock`, `error.IntegrityViolation`, `error.ParseError`,
  `error.UnknownTable`, `error.ConnectionLost` are now returned by both
  PG and MySQL drivers. Previously every failure was a generic
  `error.ExecFailed` / `error.QueryFailed`.
- **PG diagnostic extraction**: `PQresultErrorField` is used for SQLSTATE,
  primary message, table name, column name, and constraint name. Extracted
  `{table, column, constraint}` are exposed via the `Diag` struct returned
  alongside the typed error (drivers print the raw `[SQLSTATE]` for logs).
- **MySQL `errno` mapping**: `mysql_errno(conn)` / `mysql_stmt_errno(stmt)`
  are now used to classify ~15 common error codes (1062, 1451/1452, 3819,
  1048, 1205, 1213, 1064, 1146). For unique-violation (1062) we also
  parse `"for key 'table.column'"` from `mysql_error()` to surface the
  table+column just like SQLite already did.

### Tests
- **`diag.zig`**: 10 new unit tests (pgCode class 23, pgCode 40P01/55P03,
  pgCode 42xxx, pgCode empty, mysqlCode known errnos, toError round-trip,
  parseSqliteTableColumn UNIQUE/FK/no-target). All 197 tests still pass.

## [0.13.1] - 2026-06-13

### Fixed (P0)
- **Pool race in high concurrency (burst 10+)**: three improvements:
  1. `mutex_init.broadcastCond` wakes ALL waiters after `keepAlive` destroys dead connections (was signal — only one)
  2. `DB.valid` flag — set false on `deinit()`, checked in `ping()`, prevents use-after-destroy when conn still referenced
  3. `DB.ping()` checks `self.valid` before dispatching to driver

### Changed
- **Minor version bump** to 0.13.0 — `DB` struct gains `valid: bool` field (public API change)

### Fixed (P0)
- **pthread_mutex_lock silently discarded**: all `_ = std.c.pthread_mutex_lock`/`unlock` replaced with `mutex_init.lockMut`/`unlockMut` wrappers that panic on EINVAL (corrupted mutex) and EDEADLK (self-deadlock). Previously, lock failures on macOS aarch64 were silently ignored, causing pool race conditions. Also added `signalCond` wrapper with warning log, and checked `pthread_join`/`pthread_detach` return values in worker.zig.

## [0.12.8] - 2026-06-13

### Fixed (P0)
- **PostgresDB.ping() use-after-finish segfault**: explicit `self.conn orelse` unwrap + 0xaa poison guard in PostgresDB and MySQLDB ping/exec/query. Zig 0.17's auto-unwrap of `?*c.PGconn` to `*PGconn` silently passes poisoned pointers to C functions. Now explicitly checks for null and 0xaaaaaaaaaaaaaaaa fill pattern before every C call.

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
