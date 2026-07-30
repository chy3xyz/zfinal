# ADR-010: Smart routing (actions.zig true source)

**Status**: Accepted  
**Date**: 2026-07-30

## Context

Greenfield ZFinal needs one URL dialect and an AI-auditable route table without runtime reflection. JFinal-style convention + ActionKey is desirable, but Zig should keep a read-only match table.

## Decision

1. Per-module `actions.zig` is the only application route source; `zf routes` generates `routes.zig` + JSON manifest.
2. URL dialect: REST + kebab-case; path params `:id` (brace `{id}` accepted at parse for transition).
3. Nested resources via `nested_under` (max depth 2); catch-all via trailing `*path` only.
4. Router match priority: static > `:param` > `*wildcard`; duplicate METHOD+path → `error.DuplicateRoute`; path match / method miss → 405 + Allow; HEAD falls back to GET.
5. Context: `param` / `wildcardPath` (reject `..`).

## Consequences

- Codegen `crud:sql` emits `:id` (fixed from `{id}`).
- `RouteGroup` wires group interceptors and gains `patch`.
- No dual URL style switch; no runtime route mutation.
