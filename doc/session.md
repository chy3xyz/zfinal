# Session & auth in production

## Default: JWT-stateless

Production apps should prefer **`createJwtAuthInterceptorWithOptions(&jwt_cfg)`** (or
`createJwtAuthInterceptor`) + `jwtSign` / `jwtVerifyWithOptions`
(see `examples/production`). Config structs are **caller-owned** and must outlive the interceptor. No shared session store is required across instances.

- Claims: `sub`, `exp`, optional `nbf` / `iss` / `aud` / `role`
- Rejects `alg=none`; supports `previous_secret` for HMAC key rotation
- Env knobs in the reference example: `JWT_SECRET`, `JWT_SECRET_PREVIOUS`,
  `JWT_ISS`, `JWT_AUD`
- **RS256 verify**: `jwtVerifyRs256` / `jwt.verifyRs256` accepts PEM
  (`PUBLIC KEY` / `RSA PUBLIC KEY`) or PKCS#1 DER — for OIDC / gateway-signed
  tokens. In-process **signing** remains HS256.

## Baseline HTTP hardening (opt-in)

Wire globally (as in `examples/production`):

```zig
try app.addGlobalInterceptor(zfinal.createRequestIdInterceptor());
var sec: zfinal.SecurityHeadersConfig = .{ .include_hsts = true }; // when TLS terminates
try app.addGlobalInterceptor(zfinal.createSecurityHeadersInterceptor(&sec));
```

- `createRequestIdInterceptor`: propagate or generate `X-Request-Id`, set attr `request_id`
- `createSecurityHeadersInterceptor(*SecurityHeadersConfig)`: nosniff / frame deny / XSS / optional HSTS

## In-memory `SessionStore`

`src/core/session.zig` is **single-process only** (no TTL sweep across restarts,
no multi-instance). Fine for demos and sticky single-node deploys.

`SessionExt` on `Context` is **request-scoped attributes**, not a durable session.

## Optional: Redis sessions

When you need sticky HTML form sessions or server-side revoke lists:

```zig
var redis = try zfinal.RedisClient.init(allocator, "127.0.0.1", 6379);
try redis.connect(); // connect_timeout_ms + PING deadline
var sessions = zfinal.RedisSessionStore.init(allocator, &redis);
try sessions.put(sid, blob);
```

Redis client also applies `command_timeout_ms` on subsequent commands.

## Do not

- Ship demo `AuthInterceptor` (cookie presence only)
- Mix JWT and memory session for the same identity without a clear story
