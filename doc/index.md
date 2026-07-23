# ZFinal — AI Speedrun Zig Web Framework

> **🤖 If you are an AI agent: read `.claude/skills/zfinal-onboarding.md` first.**
> That file is the 30-second orientation. This page is the long-form
> reference. Both target the same goal: let an AI build a ZFinal
> feature in minutes, not hours.

ZFinal is a high-performance Zig web framework with a unique property:
**it is designed for AI-driven development**. Every generated file
tells the AI exactly where to add business logic. The `zf` CLI emits
machine-readable JSON. The in-framework `ZfTool` lets the AI invoke
the generator from code. The result: an AI can add a CRUD feature in
**5 minutes**.

## Why ZFinal

| Property | Why it matters for AI |
|----------|----------------------|
| `zf crud:sql <file> --json` | Emits a manifest the AI parses instead of grepping the working tree |
| `// ── ai-edit-zone: ...` markers | Edit only these blocks; regen **merges** matching zones (else `.gen.new` / `--force`) |
| `zfinal.ZfTool` (in-framework) | The AI can call the generator from Zig code, no shell out |
| `zig fmt` clean | 346+ files, all formatted; AI doesn't have to fight style |
| `zf check` | Audits AI boundary compliance; catches hand-edited generated code |
| `zig build test` | 145 tests pass, 0 leak, 0 fail; AI can rely on green CI |

## The 5-minute AI speedrun

```bash
# 1. Schema is the source of truth
cat schema.sql

# 2. Generate everything (model, service, handler, routes, tests)
zf crud:sql schema.sql --json > manifest.json

# 3. Edit only inside ai-edit-zones
$EDITOR src/modules/users/service.zig  # add business rules
$EDITOR src/modules/users/handler.zig  # add auth checks

# 4. Verify
zf check && zig build test

# 5. Run
zig build run
```

5 commands. 5 minutes. Full walkthrough in [ai-quickstart.md](ai-quickstart.md).
Runnable demo in [`examples/ai-blog-5min/`](../examples/ai-blog-5min/ZF_GEN.md).

## For AI agents

| You want to… | Read |
|--------------|------|
| Get oriented (first 30 seconds) | [`.claude/skills/zfinal-onboarding.md`](../.claude/skills/zfinal-onboarding.md) |
| Add a new feature / entity / route | [`.claude/skills/zfinal-ai-playbook.md`](../.claude/skills/zfinal-ai-playbook.md) |
| Run / fix tests or health checks | [`.claude/skills/zfinal-health.md`](../.claude/skills/zfinal-health.md) |
| Build a complete app from scratch | [`.claude/skills/zfinal-app.md`](../.claude/skills/zfinal-app.md) |
| Add a module to the framework | [`.claude/skills/zfinal-framework.md`](../.claude/skills/zfinal-framework.md) |
| Follow architecture best practices | [architecture_best_practices.md](architecture_best_practices.md) |
| Scale to millions of users (ops topology) | [scale_to_millions.md](scale_to_millions.md) |
| Reverse proxy + force close (keep-alive) | [reverse_proxy.md](reverse_proxy.md) |
| Progressive code architecture L0→L3 | [progressive_architecture.md](progressive_architecture.md) |
| Understand Zig 0.17, memory safety, etc. | [`.claude/skills/zfinal-evolution.md`](../.claude/skills/zfinal-evolution.md) |
| See a 5-minute walkthrough | [ai-quickstart.md](ai-quickstart.md) |
| Run a live demo | `zig build run-ai-blog-5min` |

## For humans

| You want to… | Read |
|--------------|------|
| Architecture best practices (layers, plugins, AI boundaries) | [architecture_best_practices.md](architecture_best_practices.md) |
| Scale-out for millions of users | [scale_to_millions.md](scale_to_millions.md) |
| nginx/Caddy + force Connection: close | [reverse_proxy.md](reverse_proxy.md) |
| Progressive app architecture (L0→L3) | [progressive_architecture.md](progressive_architecture.md) |
| 数据层：`DB` **或** `zent`（可作主力） | [zent.md](zent.md) |
| RobustMQ / Kafka messaging | [robustmq.md](robustmq.md) |
| NATS messaging | [nats.md](nats.md) |
| Understand the framework's design | [core_concepts.md](core_concepts.md) |
| Set up a project from scratch | [getting_started.md](getting_started.md) |
| Use the database / ORM | [database.md](database.md) |
| Write advanced features (interceptors, plugins, i18n) | [advanced.md](advanced.md) |
| Use the utility kits | [kits.md](kits.md) |
| Compare with JFinal (Java inspiration) | [jfinal_comparison.md](jfinal_comparison.md) |
| Migrate a legacy Java/PHP/Go/Rust project | [java_migration.md](java_migration.md) |
| Use the `zf` CLI | [zf_cli.md](zf_cli.md) |
| Build an HTMX-driven UI | [htmx_template.md](htmx_template.md) |
| Follow a full tutorial (Life3 app) | [tutorial_life3.md](tutorial_life3.md) |

## What you get out of the box

- HTTP/1.1 server with router, middleware, interceptors
- Database layer (SQLite, PostgreSQL, MySQL) with connection pool
- Active Record ORM with auto-generated CRUD
- CSRF token manager, captcha, i18n, validators
- WebSocket, template engine, metrics
- 17 utility kits (string, hash, time, file, etc.)
- 145+ unit tests + integration tests, 0 leak
- Cross-platform: macOS, Linux, Windows

## Project structure (for AI agents)

```
zfinal/
├── src/                          # Framework source
│   ├── main.zig                  # Public API
│   ├── core/                     # Server, Router, Context
│   ├── db/                       # DB + drivers + ORM
│   ├── interceptor/              # Auth, CORS, CSRF
│   ├── plugin/                   # Cache, Cron, Redis
│   ├── kit/                      # 17 utility kits
│   ├── aichat/                   # AI client + ZfTool
│   └── io_instance.zig           # Global Io + allocator
├── tools/zf/                     # CLI tool
│   ├── main.zig                  # Entry point
│   ├── codegen.zig               # Code generator
│   ├── csql.zig                  # SQL parser
│   ├── codegen_test.zig          # Generator tests
│   └── templates.zig             # Code templates
├── examples/                     # 10+ runnable examples
│   ├── hello-world/
│   ├── blog-single/
│   ├── ai-blog-5min/             # AI speedrun demo
│   └── ...
├── doc/                          # This documentation
├── .claude/skills/               # AI-recognizable skills
│   ├── zfinal-onboarding.md      # Read first
│   ├── zfinal-ai-playbook.md
│   ├── zfinal-health.md
│   ├── zfinal-framework.md
│   ├── zfinal-app.md
│   └── zfinal-evolution.md
├── .claude/agents/
│   └── zfinal-developer.md       # Sub-agent definition
├── AGENTS.md                     # Top-level rules
├── CLAUDE.md                     # Health Stack + skill routing
└── build.zig                     # Build configuration
```

## Versioning

ZFinal uses semantic versioning. Current: **v0.9.2**. Releases are
tagged on `main` and published via GitHub releases. The
`zfinal.ZfTool.manifestFromSql` version field in the manifest
matches the framework version.

## License

ZFinal is open source. See [LICENSE](../LICENSE).
