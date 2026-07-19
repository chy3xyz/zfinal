# ADR-003: Experimental plugin namespace

**Status**: Accepted  
**Date**: 2026-07-19

## Context

MQTT, P2P, DID, Agent, Queue stubs, and Java-compat stubs were exported
alongside Cache/Redis/Cron on the root `zfinal` API. README already labeled
them experimental, but code suggested they were first-class.

## Decision

Move unfinished / stub plugins under `zfinal.experimental.*`. Stable surface
keeps Plugin, PluginManager, Cache*, Redis*, Cron*.

## Consequences

- Examples (edge) import via `zfinal.experimental.*`
- Production users are less likely to wire stubs by accident
- Breaking rename for anyone who used top-level `zfinal.MqttPlugin` etc.
