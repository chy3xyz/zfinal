# 发布与质量门（productized）

> **版本**：对齐 v0.27.0 · Zig 工具链见仓库根 `.zig-version` · ADR-014  
> Related: [best_practices.md](best_practices.md) · [`PRODUCTION_AUDIT.md`](../PRODUCTION_AUDIT.md) · [module_marketplace.md](module_marketplace.md)

本地与 CI 共用**同一入口**，避免“文档里的命令列表”与流水线漂移。

## 入口

| 方式 | 命令 |
|------|------|
| Build | `zig build gate` · `zig build gate-quick` · `zig build release-gate` |
| CLI | `zf gate` · `zf gate --quick` · `zf gate --release [--strict]` · `zf release-check` |
| Script | `bash scripts/quality_gate.sh [quick\|full\|release] [--strict]` |
| Agent | 同上，加 `--json`（`zf gate --json`） |

默认模式是 **`full`**。`zf release-check` / `zig build release-gate` 默认 **`--strict`**（脏树失败）。

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
| CHANGELOG 含 `## [semver]`（不仅 Unreleased） | | | ✓ |
| `v$semver` tag 未占用（或已指向 HEAD） | | | ✓ |
| dirty working tree | | | warn / **fail if `--strict`** |

## 推荐用法

```bash
# 日常 PR / 提交前
zig build gate-quick          # 或 zf gate --quick

# 合并前 / CI 同款
zig build gate                # 或 zf gate

# 打 tag 前（vX.Y.Z）
zf release-check              # strict dirty + CHANGELOG + tag collision
git tag "v$(sed -n 's/^pub const semver = \"\(.*\)\";/\1/p' src/version.zig)"
git push origin HEAD --tags
```

## CI / 放行

| Job | 角色 |
|-----|------|
| **Quality gate (productized)** | Ubuntu 合并放行真源 = `scripts/quality_gate.sh full` |
| Test on macOS | OS 覆盖：build + test + test-zf（不重复 full gate） |
| Unit tests (ReleaseSafe) | `zig build test -Doptimize=ReleaseSafe`——抓优化/UB 相关问题；仅 Debug 可用的辅助（如 `ParamQuery.toSql`）在测试里按 `builtin.mode` 编译期排除 |
| drivers-compile / drivers-live | 可选驱动旁路，**不在** full gate 内 |
| messaging-live | NATS + Redpanda consume soak（env 门控单测） |
| zig-latest-canary | 上游 `master` 非阻塞预警（`continue-on-error`），提前暴露 std API 变动 |
| tag `v*` → `release.yml` | `scripts/quality_gate.sh release --strict` |

仓库设置建议将 **Quality gate (productized)** 设为 Required status check。

## 发布产物（`release.yml`）

tag `v*` 推送后依次：

1. `release-gate`：`quality_gate.sh release --strict`（脏树即失败）+ `install-zf -Doptimize=ReleaseSafe`；
2. `release-macos`：同样构建 macOS `zf`；
3. `publish`（唯一持有 `contents: write` 的 job）：下载两个产物 → 生成 **`SHA256SUMS`** →
   从 `CHANGELOG.md` 抽取该版本段落作为 release notes → `gh release create`。
   重复执行（重推 tag）走 `gh release upload/edit`，是幂等的。

产物命名：`zf-linux-x86_64`、`zf-macos-aarch64`；校验：
```bash
sha256sum -c SHA256SUMS   # 下载后
```

> GitHub Actions 已钉 **commit SHA**（可读版本号作为行尾注释），由 Dependabot 负责升级。
> 仍未做：artifact 签名（cosign/GPG）、覆盖率采集与 fuzz target。

## 与生产契约的关系

`zf check --prod` 覆盖生成物/边界扫描；部署清单 15 条仍在
[`PRODUCTION_AUDIT.md`](../PRODUCTION_AUDIT.md)。质量门通过 ≠ 生产审计免检。
