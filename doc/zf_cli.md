# ZF CLI 工具

`zf` 是 ZFinal 的命令行工具：项目脚手架、CRUD 生成、`routes` 智能路由、合规检查与质量门。

> **当前版本**：与仓库 `src/version.zig` / `build.zig.zon` 一致（v0.20.14+）。  
> **安装**：务必使用刚构建的二进制，避免 PATH 上残留旧版（曾有 v0.7 无 `routes`）。

## 安装

```bash
cd /path/to/zfinal
zig build install-zf
./zig-out/bin/zf version
./zig-out/bin/zf doctor --json

# 可选：放到 PATH 前面
export PATH="$(pwd)/zig-out/bin:$PATH"
```

## 命令一览（与 `zf help` 同源）

| 命令 | 作用 |
|------|------|
| `new <name>` | 新建 HTMX 模板项目 |
| `g` / `generate` | handler / model / middleware / service / task / port |
| `crud:sql` / `crud:zent` / `crud` / `crud:dsn` | 从 SQL / zent / SQLite / DSN 生成模块 |
| `routes` | 从 `actions.zig` 生成 `@generated` `routes.zig` |
| `check` | AI 边界；`--prod` 生产契约；`--practice` 业务实践；`--heal` / `--deadcode` |
| `openapi` | 最小 OpenAPI 3.0.3 |
| `gate` / `release-check` | 质量 / 发版门禁 |
| `doctor` | 诊断 PATH、版本、modules/actions 接线 |
| `market` | 本地模块市场目录 |
| `migrate` / `seed` / `admin` / `ai` / … | 见 `zf help` |

## 推荐工作流

```bash
zf new myapp && cd myapp
# 或在已有仓：
zf crud:sql schema.sql --json
zf routes --json
# 只改 ai-edit-zone
zf check
zf check --prod --root .
zf check --practice --root src   # 业务实践启发式（默认 WARN；加 --strict 升 FAIL）
# 注意：单独 `--root` 仍等价于 `--prod`；`--practice --root` 不会自动开 prod
zf doctor --json
zig build test
```

忽略实践扫描路径：在仓库根放 `.zfinal-check.json`：

```json
{ "ignore": ["vendor/", "examples/legacy/"] }
```

## Smart routing

详见 [smart_routing.md](smart_routing.md)。

```bash
zf routes --json
zf routes --check --root src/modules
```

## 生产与最佳实践

- 文档枢纽：[best_practices.md](best_practices.md)
- 生产契约：`zf check --prod [--root DIR]`（默认 `examples/production`）
- 业务实践包：`zf check --practice`（分层/SQL/信封/Outbox 等静态启发式）

## 质量门

```bash
zf gate --quick
zf gate --full
zf release-check          # tag 前；默认 --strict
```

Gate 会钉死 `$ROOT/zig-out/bin/zf`，并断言 help 含 `routes` / `doctor` 等。

## 旧文档说明

早期「controller / interceptor」叙事已废弃；生成器用 **handler / middleware / service**。请以本页与 `zf help` 为准。
