# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.8.x   | :white_check_mark: (current) |
| 0.7.x   | :white_check_mark: |
| 0.3.x   | :x:                |
| 0.2.x   | :x:                |
| 0.1.x   | :x:                |

## Reporting a Vulnerability

Please report vulnerabilities privately via [GitHub Security Advisories](https://github.com/chy3xyz/zfinal/security/advisories/new).

- You will receive an acknowledgement within 48 hours.
- We will investigate and keep you updated on progress.
- Once resolved, we will release a patch and publish a security advisory.

## Built-in Security Features

ZFinal 0.8+ includes defense-in-depth security across multiple layers:

### Cryptography
- **CSPRNG**: All random operations (tokens, captcha, UUIDs, session IDs) use the OS CSPRNG (`arc4random_buf` on macOS/BSD, `getrandom` on Linux). No deterministic PRNG seeding.
- **Password zeroing**: Database connection buffers zeroed with `@memset` after use.
- **Timing-safe comparison**: Captcha validation uses length-check-first + `std.mem.eql` for short values.

### CSRF Protection
- `TokenManager` generates 32-byte random tokens (Base64-encoded, ~43 chars).
- Single-use token semantics: `validate()` checks and removes the token atomically.
- Token expiry: configurable TTL, default 1 hour. Expired tokens are cleaned automatically.
- Token interceptor: drop-in middleware for CSRF validation on POST/PUT/DELETE routes.

### SQL Injection Prevention
- **Parameterized queries**: `execParams` and `queryParams` use native prepared statements with bound parameters.
- **Compile-time enforcement**: `Model.findWhere` requires `comptime` WHERE clause — runtime string concatenation is rejected at compile time.
- **Debug-only escape hatch**: `ParamQuery.toSql()` only compiles in Debug mode. Production builds reject it with `@compileError`.

### Rate Limiting
- Per-IP rate limiting with configurable window and max requests.
- Uses real socket address by default (not spoofable proxy headers).
- `trust_proxy_headers` must be explicitly enabled for reverse-proxy deployments.
- Automatic cleanup of stale entries prevents unbounded memory growth.

### Input Validation
- `Validator` class: required fields, email, min/max length, range, regex pattern, field matching.
- JSON depth limit: `MAX_JSON_DEPTH=64` prevents stack overflow from nested payloads.
- Request body size limits: configurable `Context.max_body_size` (default 10MB).

### Path Traversal Protection
- `FileKit.validatePath()` resolves and validates paths stay within a base directory.
- `renderFile()` rejects `..` segments and absolute paths.
- Template engine `loadTemplateFile` rejects `../` escapes outside `template_dir`.

### File Download Protection
- `renderFile()` enforces 50MB file size limit (configurable).
- Rejects directory traversal attempts at the framework level.

### Deps Initialization Safety
- `deps.zig` uses `?T = null` with panic-guarded accessors (`getPool()`, `getTokenMgr()`, `getRateLimiter()`).
- Clear panic messages if accessed before `initDeps()` called.

### Thread Safety
- All mutex locks propagate errors (`try`) or panic with clear messages.
- DB transaction rollback failures trigger `@panic` (no silent data corruption).
- 16 `catch{}` sites replaced with explicit error handling.

### Connection Security
- Connection pool health checks: `DB.ping()` before returning connections.
- Dead connections are automatically evicted and replaced.

## Security Best Practices

- **Input validation**: Always use `Validator` for user input. Never trust raw query parameters.
- **SQL**: Use `Model` ORM or `execParams`/`queryParams`. Never concatenate user input into SQL strings.
- **CSRF**: Apply `createTokenInterceptor` to all state-changing routes.
- **Rate limiting**: Enable `RateLimitHandler` on public endpoints.
- **Allocators**: Use `smp_allocator` (ReleaseFast) or `init.gpa` (Debug). Do not use `page_allocator` in request handlers.
- **Logging**: Use `-Dlog-level=warn` in production to suppress debug output.
- **Shutdown**: Call `shutdown.registerHandlers()` at startup and check `shutdown.isShuttingDown()` in your main loop.
- **Dependencies**: Keep Zig and ZFinal up to date. Check `PRODUCTION_AUDIT.md` for known issue status.
