---
name: zfinal-zent-ai
description: Use when building e-commerce, social, RBAC, or any graph-heavy ZFinal feature with the zent data layer. Triggers on "zent", "schema.zent", "crud:zent", "follow graph", "order graph", or when choosing zent as primary ORM instead of DB/Model.
---

# ZFinal × zent — AI Development Playbook

Zent is a **first-class, AI-first** data layer (peer to `DB`/`Model`). Agents must
use the generator + edit zones — never hand-write Schema/Client boilerplate.

## 30-second speedrun (zent primary)

```bash
# 1. Schema is source of truth
cat > schema.zent << 'EOF'
module shop
api_prefix /api/v1
entity User { name: string; handle: string @index }
entity Product {
  seller_id: int
  name: string
  price_cents: int
  stock: int = 0
  list_by: seller_id
}
EOF

# 2. Generate + machine manifest (ALWAYS --json for agents)
zf crud:zent schema.zent --json | tee manifest.json

# 3. Edit ONLY ai-edit-zones in generated files
# 4. Wire bootstrap snippet into main.zig (printed on stderr)
# 5. Verify
zf check && zig build test
```

## Choose this skill when

| Signal | Action |
|--------|--------|
| Dense relations / privacy / hooks | zent primary |
| Flat CRUD / existing SQL | use `zfinal-ai-playbook` + `crud:sql` instead |
| User says "电商 / 社交 / 关注图 / 订单图" | this skill |

## Agent contract

1. **Always** `zf crud:zent … --json` (or `zfinal.aichat.ZfTool.manifestFromZent`).
2. Parse `files` + `ai_edit_zones` + `next_steps` from the manifest.
3. Edit **only** inside `// ── ai-edit-zone: …` markers:
   - `model.zig` → edges / privacy
   - `persistence.zig` → custom queries (SQL stays in zent builders)
   - `service.zig` → validation / orchestration
   - `handler.zig` → auth / response shaping / extra routes
4. **Forbidden**: mix `zfinal.DB.begin` with zent Tx; rewrite generated `Create`/`Query`.
5. Verify: `zf check && zig build test`.

## In-process tool (no shell)

```zig
const tool = zfinal.aichat.ZfTool.init(allocator);
const manifest = try tool.manifestFromZent(schema_src); // .zent or JSON
const prompt = try tool.buildAgentSystemPromptZent(schema_src);
```

## DSL cheat sheet

```
module <name>
api_prefix /api/v1

entity EntityName {
  field: string|text|int|bool|float|time|uuid|bytes [@index] [@unique] [@sensitive] [@required] [@email] [@positive] [= default]
  ref: <edge_name>: <TargetEntity> via <fk_field>   # → zent From edge + QueryEdge
  policy: data_scope                                 # → 行级权限（Schema .policy）
  list_by: field_name    # optional GET list + Query Where
}
```

Constraints map to zent field chains: `@unique → .Unique()` (+ generated
`findByUnique*` + create dedup `error.Duplicate`), `@sensitive → .Sensitive()`,
`@required → .NotEmpty()` (string/text), `@email → .Email()`, `@positive →
.Positive()` (int/float). `ref:` generates `edge.From(name, Target).Field(fk)`
(+ batch `QueryEdge` usage); `policy: data_scope` attaches
`zent.data_scope.Policy` (every op needs a PrivacyContext — generator defaults
to empty ctx = allow-all). Composite-unique (e.g. Follow (a_id,b_id)) is written
by hand in `persistence.zig` custom queries + `service.zig` business rules
zones. Every entity also gets generated `update`/`delete` (PUT/DELETE routes).
JSON equivalent: see `examples/zent-shop/schema.json`.

## References

- `doc/zent.md` — positioning + anti-patterns
- `examples/zent-shop/` — full HTTP + zent demo
- `.claude/skills/zfinal-ai-playbook.md` — SQL stack sibling
