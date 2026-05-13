# ADR-001: Fiber-Based Async Server over Thread Pool

**Status**: Accepted
**Date**: 2026-05-12
**Decided by**: Claude Opus 4.7 + human review

## Context

ZFinal had two server implementations: a sync thread-pool Server and a fiber-based AsyncServer. This created maintenance burden, confused users, and split feature development.

## Decision

Merge into single fiber-based Server using `Io.Threaded` + `Group.async`. Apply error-isolation pattern:

```
acceptLoopImpl() → full error set
       │ catch |e| → err_handle.set()
acceptLoop() → Cancelable!void     ← satisfies Group.async
       │
Group.async(io, acceptLoop, ...)
```

## Consequences

**Positive**:
- Single code path to maintain
- Zero heap allocation per connection (vs ConnectionTask heap alloc)
- HTTP/1.1 keep-alive support
- 503 overload protection with proper HTTP response
- ThreadPool becomes optional utility, not hard dependency

**Negative**:
- `Server.accept(io)` returns `Stream` not `Connection` — loses remote address
- `Group.async` constrains fiber return to `Cancelable!void` — requires wrapper pattern
- Cannot set thread count directly; Io.Threaded auto-detects from CPU cores

**Mitigation**:
- Remote address recovery via `getpeername()` on socket fd (future work)
- ErrorHandle pattern captures fatal errors across fibers
- Thread count config retained for future API support
