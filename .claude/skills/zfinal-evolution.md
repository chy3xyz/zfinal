---
name: zfinal-evolution
description: Use when working on any ZFinal development task that touches Zig 0.17 API quirks, memory safety (errdefer/defer/poison), thread safety (Io.Mutex), or framework conventions. Triggers on "升级", "优化", "评估", "修复", Zig 0.17 API questions, or `zig build` / `zig build test` errors in this repo.
---

# ZFinal 开发技能

当开始 ZFinal 任何开发工作时，自动激活。

## 触发条件
- 任何涉及 ZFinal (`/Users/n0x/w4_proj/zig_ws/zfinal`) 的代码修改
- "升级"、"优化"、"评估"、"修复" 操作
- `zig build` / `zig build test` 错误

---

## 1. Zig 0.17 关键 API 变更

| 旧 (0.16) | 新 (0.17) |
|-----------|-----------|
| `@cImport({...})` | `b.addTranslateC(...)` in build.zig + `@import("c_module")` |
| `std.fmt.bufPrintZ(...)` | `std.fmt.bufPrint(...)` + `buf[len] = 0` + `[:0]` cast |
| `allocator.dupeZ(u8, s)` | `allocator.allocSentinel(u8, s.len, 0)` + `@memcpy` |
| `std.ascii.indexOfIgnoreCase` | `std.ascii.startsWithIgnoreCase` |
| `comptimePrint` loops | `@setEvalBranchQuota(20000)` |
| minimum_zig_version | `"0.17.0"` |

## 2. 内存安全规则 (ZBP 对齐)

### 每请求检查清单
```bash
# 分配无 defer 检查
grep -n '\.alloc\|\.create(' *.zig | grep -v 'defer\|errdefer'

# ArrayList 无 deinit 检查
grep -n 'ArrayList.*\.empty' *.zig  # 下一行必须有 defer .deinit

# 测试泄漏检查
zig build test --summary all 2>&1 | grep -E 'leak|pass'
```

### 关键模式
- **errdefer**: 每次 `try` 分配后立即 `errdefer cleanup`
- **defer if**: 可选资源用 `var x: ?T = null; defer if (x) |v| v.deinit();`
- **毒化**: 每个 `deinit()` 以 `self.* = undefined;` 结尾
- **倒序**: deinit 释放顺序与 init 分配顺序相反

## 3. 线程安全规则

- **Io.Mutex**: 新代码用 `std.Io.Mutex`, 不用 `pthread_mutex_t`
- **void 函数锁失败**: `m.lock(io) catch @panic("name: mutex lock failed")`
- **!T 函数锁失败**: `try m.lock(io)` — 传播错误
- **全局状态**: 用 `?T = null` + 断言访问器, 不用 `var x = undefined`
- **原子**: 计数器/标志位用 `std.atomic.Value(T)`

## 4. 安全审查

### 每次修改 DB 代码时
- [ ] 搜索 `exec(` → 必须是 comptime SQL 或零用户输入的常量
- [ ] 搜索 `interpolate` 或 `fmt` 拼接 SQL → SQL 注入风险
- [ ] 确认参数用 `execParams`/`queryParams` 传递

### 每次修改文件 I/O 时
- [ ] 搜索 `openFile(` → 路径含 `..` 或绝对路径检查
- [ ] 搜索 `renderFile` → 文件大小限制

### 每次修改认证/会话时
- [ ] 搜索 `password` → `@memset` 清零
- [ ] 搜索 `random` → 使用 OS CSPRNG (非 PRNG)
- [ ] 搜索 `token` → TTL 检查, 一次性使用

## 5. 性能规则

- **路由**: 静态路由自动走 HashMap O(1), 参数路由 O(n)
- **拦截器**: 使用 `ensureTotalCapacity` + `appendAssumeCapacity`
- **分配器**: 生产用 `smp_allocator`, 测试用 `testing.allocator`, 不用 `page_allocator`
- **Context**: 每次请求 3 个 HashMap 初始化 (lazy, 首次 put 才分配)

## 6. 代码生成规则 (zf)

- 生成文件有 `// @generated` 头部
- v0.8.0+: 文件名为 `model.zig`/`service.zig`/`handler.zig` (非 `.gen.zig`)
- **永远不要**无条件覆盖已有文件
- 用 `zf check` 审计生成/编辑边界
- handler: parseId 返回错误 400, 非 catch 0
- handler: update 调用 service.update(), 非手动字段复制

## 7. 测试基线

```
zig build                  # 28/28 steps
zig build test             # 146 total, 144 pass, 2 skip, 0 failed, 0 leaks
zig build test --summary all  # 完整输出
```

### Zig 0.17-dev 测试 runner 规避

当前 pinned 版本 `0.17.0-dev.1422+e863bf3be`（CI）的 server-mode test runner 可能通过 `--listen=-` 与 build server 通信并触发 `EndOfStream` panic。`build.zig` 已改为直接运行编译好的测试二进制：

```zig
const run_lib_unit_tests = b.addRunFile(lib_unit_tests.getEmittedBin());
run_lib_unit_tests.expectExitCode(0);
```

如果输出末尾出现 `failed command:` 但前面已打印 `144 passed; 2 skipped; 0 failed.`，以 exit code 为准（应为 0），该行只是 build system 的 cosmetic 输出。

## 8. 项目状态

| 维度 | 评分 | 说明 |
|------|------|------|
| 质量 | A- | 80+ ZBP 修复, 0 leaks |
| 安全 | B+→A- | 路径穿越/密码/SQLi/CSRF 已加固 |
| 性能 | A- | Fiber I/O, O(1) 路由, 预分配 |
| 测试 | 144/146 | 2 skip (跨平台/需要外部服务) |
| Zig 版本 | 0.17.0 | 已完全迁移 |

## 9. 已知问题

- `SQLite step failed: 19` — `db: constraint violation on SQLite` 测试故意触发唯一约束冲突，错误已被捕获，测试通过；该日志为预期噪声
- PG/MySQL 驱动需 `-Ddriver_pg=true` / `-Ddriver_mysql=true` + 系统库
- `pool.zig` 保留 `pthread_mutex_t` (与 `pthread_cond_timedwait` 深度耦合)
- Windows CSPRNG 弱回退 (Zig 0.17 stdlib 未暴露 BCryptGenRandom)

## 10. 健康检查

质量仪表盘见 `CLAUDE.md` ## Health Stack，或加载 skill `zfinal-health`。

## 11. 相关文件

- `CLAUDE.md` — 框架架构 + 构建命令
- `AGENTS.md` — AI 代码生成规则
- `PRODUCTION_AUDIT.md` — 生产就绪评分卡
- `SECURITY.md` — 安全策略
- `CHANGELOG.md` — 版本历史
