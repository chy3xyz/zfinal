# 发布与质量门（productized）

> **版本**：对齐 v0.20.9+ · ADR-014  
> Related: [best_practices.md](best_practices.md) · [`PRODUCTION_AUDIT.md`](../PRODUCTION_AUDIT.md) · [module_marketplace.md](module_marketplace.md)

本地与 CI 共用**同一入口**，避免“文档里的命令列表”与流水线漂移。

## 入口

| 方式 | 命令 |
|------|------|
| Build | `zig build gate` · `zig build gate-quick` · `zig build release-gate` |
| CLI | `zf gate` · `zf gate --quick` · `zf gate --release` · `zf release-check` |
| Script | `bash scripts/quality_gate.sh [quick\|full\|release]` |
| Agent | 同上，加 `--json`（`zf gate --json`） |

默认模式是 **`full`**。

## 模式对照

| 检查项 | quick | full | release |
|--------|:-----:|:----:|:-------:|
| `src/version.zig` ↔ `build.zig.zon` | ✓ | ✓ | ✓ |
| `zig fmt --check` | ✓ | ✓ | ✓ |
| `zig build` | ✓ | ✓ | ✓ |
| `zig build test` | ✓ | ✓ | ✓ |
| `zig build test-zf` | ✓ | ✓ | ✓ |
| `zig build -Doptimize=ReleaseSafe` + `production` bin | | ✓ | ✓ |
| `zf check --prod` | | ✓ | ✓ |
| `zf routes --check`（smart-routing / production） | | ✓ | ✓ |
| CHANGELOG 含 `## [semver]` 或 `## [Unreleased]` | | | ✓ |
| dirty working tree | | | warn |

## 推荐用法

```bash
# 日常 PR / 提交前
zig build gate-quick          # 或 zf gate --quick

# 合并前 / CI 同款
zig build gate                # 或 zf gate

# 打 tag 前（vX.Y.Z）
zf release-check              # 或 zig build release-gate
git tag v$(sed -n 's/^pub const semver = \"\(.*\)\";/\1/p' src/version.zig)
```

## CI

`.github/workflows/ci.yml` 的 **Quality gate** job 调用
`scripts/quality_gate.sh full`。矩阵 OS 上的单测任务可并存，但“是否放行”
以该脚本定义为准。

Tag 推送可走 `.github/workflows/release.yml`（`release` 模式）。

## 与生产契约的关系

`zf check --prod` 覆盖生成物/边界扫描；部署清单 15 条仍在
[`PRODUCTION_AUDIT.md`](../PRODUCTION_AUDIT.md)。质量门通过 ≠ 生产审计免检。
