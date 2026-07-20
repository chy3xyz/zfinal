# Session & auth in production

## Default: JWT-stateless

Production apps should prefer **`createJwtAuthInterceptor`** + `jwtSign` /
`jwtVerifyWithOptions` (see `examples/production`). No shared session store is
required across instances.

- Claims: `sub`, `exp`, optional `nbf` / `iss` / `aud` / `role`
- Rejects `alg=none`; supports `previous_secret` for HMAC key rotation
- RS256 is **not** implemented yet — terminate OIDC at a gateway or contribute later

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
