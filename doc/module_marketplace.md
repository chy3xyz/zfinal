# 模块市场（phase 1：本地目录）

> **版本**：对齐 v0.20.10+ · ADR-015  
> Related: [release_and_quality_gates.md](release_and_quality_gates.md) · [progressive_architecture.md](progressive_architecture.md) · [zent.md](zent.md)

先有可发现的**本地目录**，再谈远程安装。质量门（ADR-014）优先于市场扩张。

## 现状（phase 1）

| 能力 | 状态 |
|------|------|
| `marketplace/catalog.json` | ✓ 策展条目 |
| `zf market list` | ✓ |
| `zf market search <q>` | ✓ |
| `zf market info <id>` | ✓ |
| `--json` / `--catalog PATH` | ✓ |
| 远程 registry / `install` | ✗ 未做（phase 2+） |

## 用法

```bash
zf market list
zf market search zent
zf market info example/zent-shop
zf market search ports --json
```

条目里的 `path` 指向仓库内示例或插件源码；接入方式仍是读文档 + 复制/接线，
或继续用 `zf crud:*` / `zf g` 生成，**不要**手写整模块骨架。

## 登记格式（schema_version: 1）

```json
{
  "id": "example/zent-shop",
  "name": "zent Shop",
  "kind": "example|plugin|module",
  "path": "examples/zent-shop",
  "summary": "one-line",
  "tags": ["zent", "ecommerce"],
  "min_zfinal": "0.20.0",
  "doc": "doc/zent.md"
}
```

新增官方示例：先合入 `examples/`，再往 `catalog.json` 加一行，并保证
`zig build gate` 仍绿。

## Phase 2+（刻意延后）

- 远程索引与签名包
- `zf market install <id>` + `build.zig.zon` 依赖写入
- 与 `zf gate` / CI 的安装后回归钩子

在质量门与版本纪律稳定前，不做远程市场。
