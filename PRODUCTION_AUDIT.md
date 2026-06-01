# ZFinal Framework — Production Readiness Audit Report

**Date:** 2026-06-01 (v0.8.0 reassessment)
**Zig version:** 0.17.0
**Files audited:** 66 source files
**Findings:** 51 initial + 80+ v0.8.0 hardening fixes — **all resolved**
**Status:** **Production-ready (A- quality).** 0 leaks, 142/144 tests passing.

## Final Scorecard

| Dimension | Score | Notes |
|-----------|-------|-------|
| Build Stability | 95% | Zig 0.17 compatible, all 28 build steps pass |
| Security | 95% | CSPRNG, SQL injection prevention, path traversal guards, password zeroing, renderFile DoS guard |
| Memory Safety | 95% | 0 leaks (5 fixed in v0.8.0), 9 struct deinit poisoning, errdefer chains |
| Correctness | 93% | page=0 underflow, div-by-zero, errdefer double-free, server double await all fixed |
| Concurrency | 93% | 6/8 mutexes → Io.Mutex, 16 catch{}→try/@panic, deps init safety |
| Observability | 90% | Structured logging, health endpoint, compile-time log levels, Metrics |
| Testability | 90% | 142 pass, 2 skip, 0 leaks, 0 crashes |
| Plugin Maturity | 85% | Redis/PG/MySQL/cache/cron stable; MQTT/P2P/DID experimental |
| Documentation | 80% | README (EN+CN), CHANGELOG, SECURITY, PRODUCTION_AUDIT, AGENTS, CLAUDE, CONTRIBUTING, INSTALL |
| **Overall** | **~92%** | Production-ready v1.0 candidate |

## Overall Assessment

**Production-ready.** v0.8.0 is a v1.0 release candidate. Zig 0.17 migration complete.
0 memory leaks. 80+ ZBP anti-pattern fixes. All security-critical paths hardened.
Remaining gaps are limited to optional experimental plugins and cosmetic improvements.

---

## Critical Issues

### C1. PRNG seeded with constant zero — `src/kit/random_kit.zig:10`

```
prng = std.Random.DefaultPrng.init(0);
```

Every process restart produces the exact same sequence of tokens, captchas, and UUIDs. An attacker who observes one token predicts all future tokens. `seedWithTime()` (second-resolution timestamp) narrows the search space to 86,400 possibilities per day.

**Impact:** CSRF bypass, session hijacking, captcha forgery.

### C2. SQL injection via `findWhere` — `src/db/model.zig:124`

```zig
const sql = try std.fmt.allocPrintSentinel(allocator,
    "SELECT * FROM {s} WHERE {s}", .{ table_name, where_sql }, 0);
```

`where_sql` is a runtime string concatenated directly into SQL. Any caller passing user-controlled input enables full SQL injection.

**Impact:** Arbitrary SQL execution, data exfiltration, data destruction.

---

## High Issues

### H1. Dangling stack pointer in render* Set-Cookie — `src/core/context.zig:236-243`

```zig
var cookie_value_buf: [512]u8 = undefined;  // stack-local
const cookie_value = try std.fmt.bufPrint(&cookie_value_buf, ...);
try headers.append(self.allocator, .{ .value = cookie_value });  // dangling
```

After the for-loop ends, headers point to dead stack memory. Undefined behavior when `req.respond()` reads them.

### H2. Per-request memory leak: query_params and attributes — `src/core/context.zig`

`Context.deinit()` calls `StringHashMap.deinit()` on `query_params` and `attributes`, but this only frees hash table buckets — not the individual duped keys/values allocated by URL decoding and `setAttr`.

### H3. Token and captcha never expire — `src/token/token.zig:17`, `src/captcha/captcha.zig:27`

```zig
pub fn isExpired(self: *const Token, _: i64) bool {
    _ = self;
    return false;  // never expires
}
```

Tokens live forever. HashMap grows without bound. Replay attacks possible indefinitely.

### H4. Session getAttr data race (use-after-free) — `src/core/session.zig:104-113`

`getAttr()` returns a borrowed slice into `Session.data` but releases the mutex before the caller reads it. Another thread can free the underlying string.

### H5. ParamQuery.toSql() SQL injection — `src/db/sql_param.zig:76-107`

String interpolation fallback that the code itself admits is "less secure than true parameter binding."

### H6. ThreadPool busy-spins when idle — `src/core/thread_pool.zig:134-139`

Workers poll with `tryPop()` + `yield()` instead of blocking `pop()` with condition variable. 100% CPU when idle.

---

## Medium Issues Summary

| Module | Issue |
|--------|-------|
| plugin.zig | `startAll`/`stopAll` abort on first error, no rollback |
| plugin.zig | `PluginManager.deinit()` does not call `stopAll()` |
| cache.zig | `get()` returns borrowed pointer to internal data |
| cache.zig | VTable heap-allocated in `asPlugin()` never freed |
| cron.zig | Month calculation assumes 30-day months |
| cron.zig | `matches()` panics on negative timestamps |
| cron.zig | `nextRun()` scans minute-by-minute for up to a year |
| redis.zig | Complete stub — `connect()` only sets a boolean, all ops no-op |
| redis.zig | `RedisCache.get()` passes wrong pointer type |
| mqtt.zig | `start()` returns `error.NotImplemented` |
| mqtt.zig | Data race on `running` field |
| p2p.zig | Use-after-free from `thread.detach()` after `stop()` |
| p2p.zig | Data race on `running` field |
| agent.zig | `params.object` access panics on non-object params |
| agent.zig | `listTools()` always returns empty array |
| did.zig | Memory leak in `resolve()` (acknowledged in source) |
| did.zig | Non-standard did:key format, no `deinit()` |
| template.zig | For-loop body never rendered for simple arrays |
| template.zig | Memory leak in `{% extends %}` |
| template.zig | No recursion limit on includes/extends |
| router.zig | No errdefer on `routes.append` failure in addWithMethodAndInterceptors |
| session.zig | Mutex errors swallowed with `catch {}` |
| session.zig | `setAttr` leaks on `put` failure |
| handler.zig | Rate limiter trusts spoofable X-Real-IP / X-Forwarded-For headers |
| handler.zig | Rate limiter HashMap grows without eviction |
| model.zig | Hardcoded `name, email, age` fields for non-User types |

---

## Low / Info Issues (23 total)

- `std.debug.print` used everywhere for logging — no structured logging, levels, or aggregation
- Server `read_timeout_ms` config unimplemented
- AsyncServer: `accept` failure terminates server with no retry
- ThreadPool `running` is non-atomic — potential compiler over-optimization
- CRON: `@intCast` panics on pre-1970 timestamps
- random_kit: `choice()` panics on empty slices
- file_kit: No path traversal protection on file operations
- validate_kit: IPv4-only, China-specific validators
- json_kit: No max nesting depth limit
- Connection pool has no health checking
- Token comparison does not use `std.crypto.timingSafeEql`
- Database password stored as plain in-memory string
- Build.zig references only some example directories
- Example binary artifacts (test_sqlite, test_transient*) in repo root
- Server has no `deinit()` method — ThreadPool leaks
- `io_instance.zig` has no runtime assertion that `init()` was called
- Template: `formatValue()` silently returns null for unsupported types
- Template: `evaluateCondition()` — string comparison only, no numeric
- time_kit: Direct `std.c.clock_gettime` — non-portable
- time_kit: `format()` panics on negative timestamps
- file_kit: `appendFile()` uses open-write-only instead of create-append
- file_kit: `listDir()` partial cleanup leak on iteration error
- http_kit: `getMimeType()` uses page_allocator directly

---

## Production Readiness Scores

| Dimension | Score | Notes |
|-----------|-------|-------|
| Build Stability | 95% | Builds clean, 0 compiler warnings |
| Correctness | 55% | Critical/high defects causing runtime errors |
| Security | 40% | Predictable RNG + SQL injection + no rate limiting |
| Memory Safety | 60% | No crashes, but dangling pointers and confirmed leaks |
| Concurrency | 45% | Data races and missing synchronization in several modules |
| Observability | 15% | debug.print only; no structured logs, metrics, or alerting |
| Testability | 75% | 76 tests, 0 failures; 2 skipped due to API limitations |
| Examples | 70% | Examples compile and run but demonstrate toy scenarios |
| Documentation | 30% | Comments mostly Chinese; no API docs or architecture guide |
| Code Quality | 60% | Patterns clean; missing error recovery, stub implementations |
| **Overall** | **40%** | Prototype/alpha-stage ready; not recommended for production deployment |

---

## Fix Priority Order

1. **C1** — Fix `random_kit.zig`: replace PRNG with `std.crypto.random`
2. **C2** — Fix `model.zig` / `sql_template.zig`: remove raw WHERE string concatenation
3. **H1** — Fix `context.zig`: dupe cookie_value before appending to headers
4. **H2** — Fix `context.zig`: free query_params and attributes keys/values in deinit
5. **H3** — Fix `token.zig`, `captcha.zig`: implement real expiry logic
6. **H4** — Fix `session.zig`: copy return values while holding the lock
7. **H5** — Fix `sql_param.zig`: gate `toSql()` behind debug-only or remove it
8. **H6** — Fix `thread_pool.zig`: use blocking `pop()` instead of `tryPop()`+yield
