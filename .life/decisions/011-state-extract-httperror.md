# ADR-011: State, extractors, HttpError mapping

**Status**: Accepted  
**Date**: 2026-07-31

## Context

Axum-style ergonomics (typed State, extractors, unified error→response) were
identified as the highest-value gaps vs ZFinal’s interceptor + string attrs model.

## Decision

1. **State**: single type-erased `Handle` on `ZFinal` → `Server` → `Context`;
   `app.setState(T, *T)` / `ctx.state(T)`.
2. **HttpError**: dedicated error set; `dispatch` renders JSON envelope; handlers
   return errors instead of ad-hoc `renderJson` for failures.
3. **extract**: thin wrappers over param/query/json/bearer.
4. **SSE**: frame helpers on `Context` atop existing `renderSSE`.
5. **oneshot**: optional test helper (`against` / `fetch`); not required for prod.

## Consequences

- Production example uses `AppState` instead of handler globals.
- 404/405 responses become JSON (breaking for clients expecting plain text).
- Interceptors may still short-circuit with their own `renderJson` (JWT/CSRF).
