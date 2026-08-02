# 模块市场（phase 2：远程索引 + install）

> **版本**：对齐 v0.20.10+ · ADR-015 + ADR-016
> Related: [release_and_quality_gates.md](release_and_quality_gates.md) · [progressive_architecture.md](progressive_architecture.md) · [zent.md](zent.md)

先有可发现的**本地目录**，再谈远程安装。质量门（ADR-014）优先于市场扩张。

## 现状（phase 2）

| 能力 | 状态 |
|------|------|
| `marketplace/catalog.json` (schema v2) | ✓ 策展条目 + `url` 制品 |
| `zf market list / search / info` | ✓（默认读缓存，`--catalog` 覆盖） |
| `zf market update [--registry URL]` | ✓ 远程索引同步 → `~/.cache/zf/` |
| `zf market install <id>` | ✓ 下载 → 解压 → 落位 |
| 签名包 / `build.zig.zon` 自动 merge | ✗ 未做（phase 2c） |

## 用法

```bash
zf market update                              # 同步远程目录（默认 GitHub raw）
zf market list
zf market search zent
zf market info example/zent-shop
zf market search ports --json
zf market install example/zent-shop --dry-run # 只看计划
zf market install example/zent-shop --dir vendor/x
zf market install plugin/metrics              # → src/plugin/
```

## 登记格式（schema_version: 2）

```json
{
  "id": "example/zent-shop",
  "name": "zent Shop",
  "kind": "example|plugin|module",
  "path": "examples/zent-shop",
  "summary": "one-line",
  "tags": ["zent", "ecommerce"],
  "min_zfinal": "0.20.0",
  "doc": "doc/zent.md",
  "url": "https://github.com/chy3xyz/zfinal/archive/refs/tags/v0.20.3.tar.gz"
}
```

- `url` 指向制品 tarball；`path` 是 tarball 内的子目录/文件（GitHub archive 的
  顶层 `<repo>-<tag>/` 前缀在安装时自动跳过）。
- 新增官方示例：先合入 `examples/`，再往 `catalog.json` 加一行，并保证
  `zig build gate` 仍绿。

## Phase 2c（刻意延后）

- 签名包与校验（第三方发布时才需要）
- `zf market install` 对 package 型模块自动写 `build.zig.zon` 依赖
- 安装后的 `zf gate` / CI 回归钩子

在质量门与版本纪律稳定前，不做远程市场扩张。
