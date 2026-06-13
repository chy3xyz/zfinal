# CLAUDE.md

## Health Stack

- typecheck: zig build
- lint: zig fmt --check src/ test/ benchmark/ tools/ examples/ build.zig
- test: zig build test
- deadcode: (none available for Zig)
- shell: (none available)

## ZFinal Development Notes

- Use `zf` CLI tools for code generation; never hand-write model/handler/service code from scratch (see `AGENTS.md`).
- `zig build test` runs 146 tests; expected baseline is `144 passed; 2 skipped; 0 failed.`
- On Zig `0.17.0-dev.813+2153f8143`, the server-mode test runner crashes with `EndOfStream`; `build.zig` works around this by running the compiled test binary directly via `b.addRunFile(lib_unit_tests.getEmittedBin())`.
- If test output ends with `failed command:` but the summary line shows 144 passed and exit code is 0, treat it as a cosmetic build-system message.
- `SQLite step failed: 19` is expected noise from the intentional constraint-violation test.
- Generated migration artifacts (`zfinal_migration.zig`, `test_final/zfinal_migration.zig`) are gitignored and may be deleted if they interfere with linting.
