# CLAUDE.md

## Skill routing

When the user's request matches an available skill, invoke it via the Skill tool. When in doubt, invoke the skill.

Key routing rules for this project:

- Add a new entity / regenerate from SQL → invoke `zfinal-ai-playbook`
- Health check / CI / `zig build test` issues → invoke `zfinal-health`
- Add a new module / fix framework internals → invoke `zfinal-framework`
- Build a ZFinal app from scratch → invoke `zfinal-app`
- General ZFinal development (Zig 0.17, memory safety, CSRF) → invoke `zfinal-evolution`

## Health Stack

- typecheck: zig build
- lint: zig fmt --check src/ test/ benchmark/ tools/ examples/ build.zig
- test: zig build test
- deadcode: (none available for Zig)
- shell: (none available)

## ZFinal Development Notes

- Use `zf` CLI tools for code generation; never hand-write model/handler/service code from scratch (see `AGENTS.md`).
- For the standard add-a-feature flow (SQL → edit → verify → ship), follow `zfinal-ai-playbook`.
- `zf crud:sql <file> --json` and `zf g <type> <name> --json` emit machine-readable manifests — always use `--json` when invoked by an AI agent.
- Generated files contain `// ── ai-edit-zone: …` markers. Edit only inside these zones; modify the generator template (in `tools/zf/`) if you need to change boilerplate.
- `zig build test` runs 146 tests; expected baseline is `144 passed; 2 skipped; 0 failed.`
- On Zig `0.17.0-dev.813+2153f8143`, the server-mode test runner crashes with `EndOfStream`; `build.zig` works around this by running the compiled test binary directly via `b.addRunFile(lib_unit_tests.getEmittedBin())`.
- If test output ends with `failed command:` but the summary line shows 144 passed and exit code is 0, treat it as a cosmetic build-system message.
- `SQLite step failed: 19` is expected noise from the intentional constraint-violation test.
- Generated migration artifacts (`zfinal_migration.zig`, `test_final/zfinal_migration.zig`) are gitignored and may be deleted if they interfere with linting.
