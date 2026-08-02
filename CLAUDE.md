# CLAUDE.md

## 🟢 FIRST-READ for any AI agent

If you are an AI agent and this is your first contact with this project,
**read `.claude/skills/zfinal-onboarding.md` before doing anything else**.
That 30-second orientation tells you the framework, the 5-command speedrun,
and which skill to load next. This CLAUDE.md is the persistent reference;
on subsequent visits you can skip the onboarding.

## Skill routing

When the user's request matches an available skill, invoke it via the Skill tool. When in doubt, invoke the skill.

Key routing rules for this project:

- **First contact / "what is zfinal" / orientation** → invoke `zfinal-onboarding`
- Add a new entity / regenerate from SQL → invoke `zfinal-ai-playbook`
- E-commerce / social / graph / `schema.zent` / `crud:zent` → invoke `zfinal-zent-ai`
- Health check / CI / `zig build test` issues → invoke `zfinal-health`
- Add a new module / fix framework internals → invoke `zfinal-framework`
- Build a ZFinal app from scratch → invoke `zfinal-app`
- General ZFinal development (Zig 0.17, memory safety, CSRF) → invoke `zfinal-evolution`

There is also a sub-agent `zfinal-developer` in
`.claude/agents/zfinal-developer.md` that bundles the onboarding +
playbook + hard rules into a single auto-dispatched unit. If the host
supports sub-agents, dispatching that is equivalent to invoking
`zfinal-onboarding` followed by the appropriate task-specific skill.

## Health Stack

Prefer the productized gate (see `doc/release_and_quality_gates.md`):

- day-to-day: `zig build gate-quick` / `zf gate --quick`
- merge / CI: `zig build gate` / `bash scripts/quality_gate.sh full`
- pre-tag: `zf release-check` / `zig build release-gate`
- typecheck: zig build
- lint: zig fmt --check src/ test/ benchmark/ tools/ examples/ build.zig
- test: zig build test
- codegen-regression: zig build test-zf
- deadcode: `zf check --deadcode` (vendored [zdeadcode](https://github.com/chy3xyz/zdeadcode))
- shell: scripts/quality_gate.sh (productized)

## ZFinal Development Notes

- Use `zf` CLI tools for code generation; never hand-write model/handler/service code from scratch (see `AGENTS.md`).
- For the standard add-a-feature flow (SQL → edit → verify → ship), follow `zfinal-ai-playbook`.
- `zf crud:sql <file> --json` and `zf g <type> <name> --json` emit machine-readable manifests — always use `--json` when invoked by an AI agent.
- Generated files contain `// ── ai-edit-zone: …` markers. Edit only inside these zones; modify the generator template (in `tools/zf/`) if you need to change boilerplate.
- `zig build test` runs unit tests; expected baseline is `369 passed; 17 skipped; 0 failed.`
  (extra skips when `NATS_URL` / `ROBUSTMQ_URL` / `ZF_PG_*` / `ZF_MY_*` / `OAUTH2_LIVE` unset —
  CI `messaging-live` / `drivers-live` enable them.)
- On Zig `0.17.0-dev.1422+e863bf3be`, the server-mode test runner may crash with `EndOfStream`; `build.zig` works around this by running the compiled test binary directly via `b.addRunFile(lib_unit_tests.getEmittedBin())`.
- If test output ends with `failed command:` but the summary line shows 144 passed and exit code is 0, treat it as a cosmetic build-system message.
- `SQLite step failed: 19` is expected noise from the intentional constraint-violation test.
- Generated migration artifacts (`zfinal_migration.zig`, `test_final/zfinal_migration.zig`) are gitignored and may be deleted if they interfere with linting.
