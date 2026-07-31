# ADR-013: Default JSON error envelope stays REST/HttpError

**Status**: Accepted  
**Date**: 2026-07-31

## Context

BFF ecosystems (ThinkPHP / ruoyi / ZigShop) often use `{ "code", "msg", "data" }` (zapi).
Axum-style ergonomics and OpenAPI already document `{ "err", "msg", "detail"? }` with HTTP
status as the primary signal (`http_error.render`).

## Decision

1. **Framework default remains** `{ err, msg, detail? }` via `HttpError` + HTTP status.
2. **zapi is an application convention**: success and failure must both use `{code,msg,data}`;
   do not change only the error path.
3. Document the choice in [`doc/api_envelope.md`](../../doc/api_envelope.md); link from
   architecture best practices and HTTP ergonomics.

## Consequences

- OpenAPI `HttpError` schema and `zf` codegen stay stable.
- Apps that need zapi own a thin `response.ok` / `response.fail` helper.
- A future optional framework helper for zapi would be additive, not a default flip.
