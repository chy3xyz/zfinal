# ADR-004: Promote selected experimental plugins to stable

**Status**: Accepted  
**Date**: 2026-07-19

## Context

Several plugins lived under `zfinal.experimental` as stubs or half-finished
demos. Users need production-usable CircuitBreaker, in-process Queue, DID
signing, MCP tool routing, MQTT publish, and Metrics export without optional
network dependencies.

## Decision

Promote to stable (root `zfinal.*` exports) with unit tests:

- CircuitBreaker, QueueClient, DidPlugin, AgentPlugin, MetricsExporter,
  MqttPlugin (QoS0 client), ObjectMapper

Remain experimental: (none for messaging — NATS promoted in ADR-005 / v0.13.9)

## Consequences

- Breaking: `zfinal.experimental.CircuitBreaker` etc. moved to `zfinal.*`
  (compat aliases remain in stubs for CircuitBreaker/MetricsExporter only).
- Edge example imports stable MQTT/Agent/DID; P2P stays experimental.
- MQTT subscribe / QoS>0 still out of scope for this release.
