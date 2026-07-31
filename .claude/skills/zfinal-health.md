---
name: zfinal-health
description: Use when running code quality checks, CI validation, or health dashboards on the ZFinal Zig web framework. Triggers on /health, "code quality", "run tests", zig build test failures, or zig fmt --check output.
---

# ZFinal Health Check

Run the project's own tools and score the result. Never substitute manual analysis for tool output.

## Health Stack

Configured in `CLAUDE.md`. Prefer the **productized gate** over ad-hoc command lists:

| Mode | Command |
|------|---------|
| Day-to-day | `zig build gate-quick` / `zf gate --quick` |
| Merge / CI | `zig build gate` / `zf gate` / `bash scripts/quality_gate.sh full` |
| Pre-tag | `zf release-check` / `zig build release-gate` |

| Category | Command (gate covers these) |
|----------|---------|
| Type check | `zig build` |
| Lint | `zig fmt --check src/ test/ benchmark/ tools/ examples/ build.zig` |
| Tests | `zig build test` + `zig build test-zf` |
| Prod contract | `zf check --prod` (full/release) |
| Dead code | (no Zig tool available) |

Docs: `doc/release_and_quality_gates.md` (ADR-014). Marketplace discover: `zf market list` (ADR-015).

## Known Zig 0.17-dev Quirk

`zig build test` on Zig `0.17.0-dev.1422+e863bf3be` may crash the server-mode test runner with `EndOfStream`. `build.zig` works around this by running the compiled test binary directly:

```zig
const run_lib_unit_tests = b.addRunFile(lib_unit_tests.getEmittedBin());
run_lib_unit_tests.expectExitCode(0);
```

If you see `failed command:` after `144 passed; 2 skipped; 0 failed.`, check the exit code. Exit 0 means tests passed; the line is cosmetic output from the build system.

## Quick Fixes

```bash
# Format all project code
zig fmt .

# Delete generated migration artifacts if lint flags them
rm -f zfinal_migration.zig test_final/zfinal_migration.zig

# Run full verification (prefer productized gate)
zig build gate
# or: zig build && zig fmt --check src/ test/ benchmark/ tools/ examples/ build.zig && zig build test
```

## Scoring

- Type check / lint / tests: clean exit 0 = 10/10
- Skipped categories redistribute weight proportionally
- With all three green, composite score is 10.0

## When Tests Fail

1. Read the actual test summary line (`N passed; M skipped; K failed.`)
2. If the runner itself crashes before printing results, the Zig version likely regressed; try `0.17.0-dev.1422+e863bf3be` or the version pinned in CI / `build.zig.zon` if present.
3. SQLite `step failed: 19` is expected noise from the constraint-violation test; it is caught and the test passes.
