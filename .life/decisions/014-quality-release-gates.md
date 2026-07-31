# ADR-014: Productized quality & release gates

**Status**: Accepted  
**Date**: 2026-07-31

## Context

CI already runs fmt / test / test-zf / ReleaseSafe / `zf check --prod` as separate
jobs. Contributors and AI agents still reassemble ad-hoc command lists from
`CLAUDE.md` / `AGENTS.md`, which drifts from CI and misses release-time
checks (version sync, CHANGELOG).

## Decision

1. **Single script** [`scripts/quality_gate.sh`](../../scripts/quality_gate.sh)
   with modes `quick` | `full` (default) | `release`.
2. **Build steps**: `zig build gate` / `gate-quick` / `release-gate`.
3. **CLI**: `zf gate [--quick|--full|--release]` and `zf release-check`
   (alias for `--release`); both support `--json` for agents.
4. **CI** runs `scripts/quality_gate.sh full` as the productized gate job;
   matrix OS jobs may remain for coverage.
5. Document the contract in [`doc/release_and_quality_gates.md`](../../doc/release_and_quality_gates.md).

## Consequences

- Local pre-push and CI share one definition of “green”.
- Tagging requires `release` mode (CHANGELOG heading + dirty-tree warn).
- Marketplace / feature work must not ship without the gate staying green.
