# ADR-012: Axum-inspired ergonomics pass (Extension, layers, fallback, capture)

**Status**: Accepted  
**Date**: 2026-07-31

## Context

Nine Axum/tower-http style gaps remained after ADR-011 (State/extract/HttpError).

## Decision

1. **Typed Extension** — `ctx.setExt` / `ctx.ext(T)` request-scoped bag (≠ `setState`).
2. **Interceptor failures** — JWT/CSRF return `HttpError`; `dispatch` renders JSON; `response_started` avoids double-write. CORS OPTIONS may still short-circuit with `return false` after respond.
3. **Fallback / merge** — `Router.setFallback` / `ZFinal.setFallback`; `ZFinal.merge(&.{registerA, registerB})`.
4. **Stock layers** — `zfinal.stock`: body_limit, timeout, compression, trace.
5. **ServerConfig.compress_responses** — default gzip negotiation flag.
6. **oneshot.capture** — in-process `Router.execute` via `Context.capture` (no TCP; no `ctx.req` reads).
7. **OpenAPI** — `components.schemas.HttpError` + $ref on 400/401/404/422/429.
8. **SSE** — `ctx.sseWrite` / `client_gone` for WriteFailed backpressure.
9. **DI** — ports-l2/l3 use `setState`; no service locator.

## Consequences

- Interceptor authors should prefer `return error.Unauthorized` over hand-rolled JSON.
- Capture tests cannot exercise header/body-dependent handlers (use TCP `against` for those).
