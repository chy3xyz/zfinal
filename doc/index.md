# ZFinal — AI Speedrun Zig Web Framework

> **🤖 If you are an AI agent: read `.claude/skills/zfinal-onboarding.md` first.**  
> **Best practices hub:** [best_practices.md](best_practices.md)（任务索引 + v0.20.x 能力时间线）

ZFinal is a high-performance Zig web framework **designed for AI-driven development**.
Generated files mark `// ── ai-edit-zone: …`; `zf` emits JSON manifests; `zfinal.ZfTool`
can invoke generators in-process. Current release: **v0.20.15** (Zig `0.17.0-dev.1422`).

## Why ZFinal

| Property | Why it matters for AI |
|----------|----------------------|
| `zf crud:sql` / `zf crud:zent` `--json` | Manifest instead of grepping the tree |
| `ai-edit-zone` + zone **merge** | Regen keeps matching zone bodies |
| `zf routes` + `actions.zig` | One routing source of truth (v0.20.9+) |
| `zfinal.ZfTool` | In-process generator, no shell required |
| `zf check` / `--heal` / `--prod` | Boundary + HttpError + production contract + L3 heuristics |
| `zig build test` | **379 passed; 17 skipped; 0 failed** (baseline; live env adds more) |

## The 5-minute AI speedrun

```bash
cat schema.sql
zf crud:sql schema.sql --json > manifest.json
# Edit only ai-edit-zones → zf check && zig build test → zig build run
```

Path B (graphs / e-commerce): `zf crud:zent schema.zent --json`.  
Walkthrough: [ai-quickstart.md](ai-quickstart.md) · Demo: `examples/ai-blog-5min/`.

## For AI agents

| You want to… | Read |
|--------------|------|
| First 30 seconds | [`.claude/skills/zfinal-onboarding.md`](../.claude/skills/zfinal-onboarding.md) |
| Best-practice hub (start here for architecture) | [best_practices.md](best_practices.md) |
| Add feature / CRUD | [`.claude/skills/zfinal-ai-playbook.md`](../.claude/skills/zfinal-ai-playbook.md) |
| zent / e-commerce | [`.claude/skills/zfinal-zent-ai.md`](../.claude/skills/zfinal-zent-ai.md) |
| Health / CI | [`.claude/skills/zfinal-health.md`](../.claude/skills/zfinal-health.md) |
| Architecture layers | [architecture_best_practices.md](architecture_best_practices.md) |
| SaaS Kit / SolidStart API | [saas_kit.md](saas_kit.md) |
| Envelopes / smart routing / HTTP | [api_envelope.md](api_envelope.md) · [smart_routing.md](smart_routing.md) · [http_ergonomics.md](http_ergonomics.md) |
| L0→L3 / Outbox→Bus / millions | [progressive_architecture.md](progressive_architecture.md) · [outbox.md](outbox.md) · [bus.md](bus.md) · [scale_to_millions.md](scale_to_millions.md) |
| Keep-alive / reverse proxy | [reverse_proxy.md](reverse_proxy.md) |
| Business AI runtime | [ai.md](ai.md) |

## For humans

| You want to… | Read |
|--------------|------|
| Best practices index + timeline | [best_practices.md](best_practices.md) |
| Architecture / progressive / scale | [architecture_best_practices.md](architecture_best_practices.md) · [progressive_architecture.md](progressive_architecture.md) · [scale_to_millions.md](scale_to_millions.md) |
| Data: `DB` **or** `zent` | [zent.md](zent.md) · [zent-commerce-social.md](zent-commerce-social.md) · [database.md](database.md) |
| SaaS Kit (org auth / Stripe / todo) | [saas_kit.md](saas_kit.md) · `examples/zfsaas/` |
| L3 async: Outbox + Bus | [outbox.md](outbox.md) · [bus.md](bus.md) |
| Messaging connectors | [nats.md](nats.md) · [robustmq.md](robustmq.md) |
| WebSocket / OAuth2 | [websocket.md](websocket.md) · [oauth2.md](oauth2.md) |
| Getting started / CLI | [getting_started.md](getting_started.md) · [zf_cli.md](zf_cli.md) |
| Production contract | [`PRODUCTION_AUDIT.md`](../PRODUCTION_AUDIT.md) |
| Quality / release gates | [release_and_quality_gates.md](release_and_quality_gates.md) |

## What you get out of the box

- HTTP/1.1 Fiber server, router, interceptors, smart routing (`actions.zig`)
- Axum-inspired State / Extension / extract / HttpError / stock layers
- SQLite (default) + opt-in PostgreSQL / MySQL; Active Record + **zent** graph ORM
- CSRF, captcha, i18n, validators, JWT HS256/RS256
- WebSocket (`addWebSocket` + idle tick), templates, metrics (6 route classes)
- Plugins: Cache / Cron / Redis / MQTT / OAuth2 / P2P (HMAC) / …
- L3 ports: `Store` / `Cache` / `Outbox` (`DbOutbox.drainOnce`) + `Bus` (Memory / NATS / RobustMQ)
- Stable `QueueNatsClient` / `QueueRobustMQClient`; CI `messaging-live` + `drivers-live`
- **369** unit tests (+ skips for live DB/MQ/OAuth2) · `test-zf` codegen · 0 leak target
- Cross-platform: macOS, Linux, Windows

## Project structure (for AI agents)

```
zfinal/
├── src/                 # Framework (main.zig = public API)
├── tools/zf/            # CLI (modular cmd_* + codegen)
├── examples/            # production, smart-routing, ports-l2/l3, zent-shop, …
├── doc/                 # Docs — start at best_practices.md / this index
├── .claude/skills/      # Agent skills
├── AGENTS.md / CLAUDE.md
└── build.zig
```

## Versioning

Semantic versioning. Current: **v0.20.15** (`src/version.zig` ≡ `build.zig.zon`).  
Tagged releases on GitHub; manifests use the same `semver`. Unreleased L3/messaging
hardening is tracked in [CHANGELOG.md](../CHANGELOG.md) `[Unreleased]`.

## License

See [LICENSE](../LICENSE).
