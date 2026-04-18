# ZFinal: Zig 0.15 → 0.16 Upgrade Guide

[English](#english) | [中文](#中文)

---

## English

### Overview

ZFinal has been successfully upgraded from Zig 0.15 to Zig 0.16! This document covers all the major changes and migration steps.

### Major Changes

#### 1. I/O System Overhaul

**Zig 0.15**:
```zig
const file = try std.fs.cwd().openFile("path", .{});
defer file.close();
```

**Zig 0.16**:
```zig
const file = try std.Io.Dir.cwd().openFile(io, "path", .{});
defer file.close(io);
```

#### 2. Network API Migration

**Zig 0.15**:
```zig
const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
const server = try std.net.StreamServer.init(allocator, .{});
```

**Zig 0.16**:
```zig
const address = try std.Io.net.IpAddress.parseIp("127.0.0.1", 8080);
const server = try address.listen(io, .{});
```

#### 3. Collection API Changes

**Zig 0.15**:
```zig
var list = std.ArrayList(T).init(allocator);
defer list.deinit();
try list.append(item);
```

**Zig 0.16**:
```zig
var list = std.ArrayList(T).empty;
defer list.deinit(allocator);
try list.append(allocator, item);
```

#### 4. Entry Point Changes

**Zig 0.15**:
```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
}
```

**Zig 0.16**:
```zig
pub fn main(init: std.process.Init) !void {
    // Initialize global Io and allocator
    @import("zfinal").io_instance.init(init);
    const allocator = init.gpa;
}
```

### Files Modified

- `src/io_instance.zig` (NEW) - Global Io instance management
- `src/main.zig` - Export Io instance
- `src/core/server.zig` - Network API update
- `src/core/context.zig` - Collection API update
- `build.zig` - Build system update
- And 20+ more files...

---

## 中文

### 概述

ZFinal 已成功从 Zig 0.15 升级到 Zig 0.16！本文档涵盖了所有主要变更和迁移步骤。

### 主要变更

#### 1. I/O 系统全面重构

**Zig 0.15**:
```zig
const file = try std.fs.cwd().openFile("path", .{});
defer file.close();
```

**Zig 0.16**:
```zig
const file = try std.Io.Dir.cwd().openFile(io, "path", .{});
defer file.close(io);
```

#### 2. 网络 API 迁移

**Zig 0.15**:
```zig
const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
const server = try std.net.StreamServer.init(allocator, .{});
```

**Zig 0.16**:
```zig
const address = try std.Io.net.IpAddress.parseIp("127.0.0.1", 8080);
const server = try address.listen(io, .{});
```

#### 3. 集合 API 变更

**Zig 0.15**:
```zig
var list = std.ArrayList(T).init(allocator);
defer list.deinit();
try list.append(item);
```

**Zig 0.16**:
```zig
var list = std.ArrayList(T).empty;
defer list.deinit(allocator);
try list.append(allocator, item);
```

#### 4. 入口点变更

**Zig 0.15**:
```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
}
```

**Zig 0.16**:
```zig
pub fn main(init: std.process.Init) !void {
    // 初始化全局 Io 和 allocator
    @import("zfinal").io_instance.init(init);
    const allocator = init.gpa;
}
```

### 修改的文件

- `src/io_instance.zig` (新增) - 全局 Io 实例管理
- `src/main.zig` - 导出 Io 实例
- `src/core/server.zig` - 网络 API 更新
- `src/core/context.zig` - 集合 API 更新
- `build.zig` - 构建系统更新
- 以及其他 20+ 个文件...

---

## Summary / 总结

**Commit**: `6ebcef4`
**Date**: April 2026
**Zig Version**: 0.16.0

This upgrade ensures ZFinal remains compatible with the latest Zig version while maintaining its high performance and minimalist API design.

本次升级确保 ZFinal 与最新的 Zig 版本兼容，同时保持其高性能和极简的 API 设计。
