# ADR-005: Promote QueueNatsClient to stable (zero-dep wire client)

**Status**: Accepted  
**Date**: 2026-07-19

## Context

`QueueNatsClient` lived under `zfinal.experimental` and required an optional
`nats.zig` package that was incompatible with current Zig 0.17-dev and not
wired into `build.zig.zon`. Meanwhile zigmodu already ships a working
zero-dependency NATS TCP client.

## Decision

1. Port zigmodu `messaging/Nats.zig` → `src/plugin/nats_client.zig`.
2. Rewrite `queue_nats.zig` as a queue-shaped façade (`connect` / publish /
   subscribe / request / poll) with `nats://` URL parsing.
3. Export `NatsClient`, `NatsConfig`, `QueueNatsClient` on the stable root API.
4. Keep `experimental.QueueNatsClient` as a deprecated alias.

## Consequences

- Default `zig build test` compiles NATS client without extra deps.
- Live smoke remains env-gated (`NATS_URL`).
- Apps no longer need `zig fetch` for nats.zig to use NATS.
