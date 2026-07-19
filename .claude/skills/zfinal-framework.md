---
name: zfinal-framework
description: Improve ZFinal framework internals. Add features, fix bugs, optimize. NOT for building apps — use zfinal-app for that.
---

# ZFinal Framework Developer

## Codebase Map

```
src/core/       Server, Router, Context, Session, Logger, Metrics, Shutdown
src/db/         DB wrapper, SQLite/PG/MySQL drivers, ConnectionPool, ORM
src/plugin/     Cache, Cron, Redis, CircuitBreaker,                 Queue, RobustMQ/Kafka, NATS, DID, Agent, MQTT, MetricsExporter, P2P,
                HttpClient, ConfigClient, OAuth2, BeanValidator, TaskScheduler,
                MessageQueue (stable)
src/kit/        17 utilities (no framework deps)
src/interceptor/ Auth, CORS, Logging, CSRF
src/token/      CSRF token gen/validate (CSPRNG)
src/captcha/    CAPTCHA (numeric, alpha, math)
src/template/   Template engine (vars, loops, conditions, includes, extends)
src/websocket/  WS frames, connection mgr, ping/pong, fragmentation
src/validator/  Input validation
src/i18n/       Internationalization, pluralization
src/main.zig    Public API exports
tools/zf/       CLI tool + codegen
```

## Quick Commands

```bash
zig build               # Build everything
zig build test          # Unit tests
zig build install-zf    # Build CLI
```

Architecture best practices (layers, plugins, AI boundaries):
`doc/architecture_best_practices.md`.

Scale-out + progressive L0→L3 app layout:
`doc/scale_to_millions.md`, `doc/progressive_architecture.md`.

## Adding a Feature

1. Create module in correct directory
2. Add tests at bottom
3. Export in `src/main.zig`
4. `zig build test` must pass
5. Update README plugin table if applicable

## .life/ Maintenance Protocol — MANDATORY

**.life/ is project hippocampus. Every session MUST read it at start, update it at end.**

### Session Start — AUTOMATIC
```
1. Read .life/dna.json        → Know version, metrics, capabilities
2. Read .life/evolution.md    → Last 2-3 entries for recent context
3. Check .life/decisions/     → Relevant ADRs for planned changes
```

### During Session — CONDITIONAL
If architecture decision made → create `.life/decisions/NNN-title.md`:
```markdown
# ADR-NNN: Title
**Status**: Proposed | Accepted | Deprecated
**Date**: YYYY-MM-DD

## Context
## Decision
## Consequences
```

### Session End — MANDATORY
Before exiting, append to `.life/evolution.md`:
```markdown
## YYYY-MM-DD — Summary line
**Session**: What was worked on
**Changes**:
1. Key change — why, how, result
2. ...
**Errors**: What failed and why (if any)
**Next**: What should follow
```

Update `.life/dna.json` if metrics changed:
```
"metrics": { "source_files": N, "tests": N, ... }
"fingerprint": { "source_hash": "COMMIT_HASH" }
```

### Milestone / Release — CONDITIONAL
When version bumps → create `.life/fingerprints/vX.Y.Z.json`:
```json
{
  "version": "v0.4.0",
  "fingerprint": "commit_hash",
  "timestamp": "ISO8601",
  "metrics": {...},
  "changes": ["change1", "change2"],
  "decisions": ["ADR-001", "ADR-002"]
}
```

### Size Constraints — MUST ENFORCE
- `evolution.md`: max 200 lines. When exceeded → keep last 10 entries, archive rest to `memory/archive-YYYY-MM.md`
- `decisions/`: max 20 files. Mark deprecated ADRs as `**Status**: Deprecated` instead of deleting
- `fingerprints/`: max 10 files. Keep latest 10, archive old to `fingerprints/archive/`
- `dna.json`: max 80 lines. Remove old capabilities, keep only current
- Single entry in evolution.md: 3-8 lines max. One sentence per change. No paragraphs.

### Anti-Patterns — NEVER
- Skip .life/ update because "changes were small"
- Write .life/ entries longer than 8 lines
- Modify old fingerprints (immutable)
- Delete .life/ files — archive instead
- Write entries without date stamp
- Add commentary/opinion to evolution.md — facts only

- `std.ArrayList(T).empty` + explicit allocator on all methods
- `std.Io.Mutex.init` (const, no parens)
- `std.Io.Timestamp.now(io, .real).toSeconds()`
- `std.json.parseFromSlice(T, allocator, json, .{})`
- Never `ArrayList.writer()` on `.empty` — use `allocPrint` + `appendSlice`
- `deinit(allocator)` everywhere
