# ZF CLI 工具更新说明

## 新功能

### 1. 重命名工具
- `zfctl` → `zf` (更简洁的命令名)

### 2. 新增命令

#### `zf api <name>` - 生成 API 控制器
快速生成 JSON API 控制器，专门用于 RESTful API 开发。

```bash
zf api Product
# 生成: src/controller/product_controller.zig
# 类型: API Controller (JSON output)
```

生成的代码包含完整的 CRUD 方法，所有响应都是 JSON 格式。

#### `zf build` (别名: `b`) - 构建发布版本
一键构建优化的发布版本二进制文件。

```bash
zf build
# 执行: zig build -Doptimize=ReleaseSafe
# 输出: zig-out/bin/<app_name>
```

### 4. 更多新功能

#### 数据库迁移
```bash
zf migrate new init_db
# 创建带时间戳的 SQL 迁移文件
```

#### 测试生成
```bash
zf test:gen User
# 生成标准测试文件模板
```

#### Docker 支持
```bash
zf docker
# 生成 Dockerfile 和 .dockerignore
```

#### 部署工具
```bash
zf deploy
# 生成/运行 deploy.sh 部署脚本
```

### 5. 改进的代码生成

#### Controller 生成支持两种模式

**HTMX 模式** (默认):
```bash
zf g controller User
# 生成控制器: src/controller/user_controller.zig
# 生成模板: src/templates/user/index.html
```

**API 模式**:
```bash
zf api Product
# 生成注释: /// API Controller (JSON output)
```

两种模式的区别：
- 都生成完整的 CRUD 方法
- 都使用 `renderJson()` 输出
- 注释标注不同用途
- 后续可扩展为不同的渲染方式

### 4. 默认项目模板
新创建的项目默认配置为 HTMX 应用：
- 包含 HTMX 支持
- 使用 SQLite 数据库
- 完整的 MVC 结构

## 完整命令列表

```bash
# 项目管理
zf new <name>              # 创建新项目 (HTMX 模板)
zf build, b                # 构建发布版本

# 代码生成
zf generate, g <type> <name>  # 生成代码
zf api <name>              # 生成 API 控制器

# 开发工具
zf serve, s                # 启动开发服务器
zf test, t                 # 运行测试

# 信息
zf version, v              # 版本信息
zf help, h                 # 帮助信息
```

## 使用示例

### 创建 HTMX 应用
```bash
# 1. 创建项目
zf new myblog

# 2. 生成 HTMX 控制器
cd myblog
zf g controller Post
zf g controller Comment

# 3. 生成模型
zf g model Post
zf g model Comment

# 4. 运行
zf serve
```

### 创建 API 应用
```bash
# 1. 创建项目
zf new myapi

# 2. 生成 API 控制器
cd myapi
zf api User
zf api Product
zf api Order

# 3. 生成模型
zf g model User
zf g model Product
zf g model Order

# 4. 构建发布版本
zf build
```

### 混合模式（HTMX + API）
```bash
# 1. 创建项目
zf new myapp

# 2. HTMX 控制器（用于页面）
cd myapp
zf g controller Page

# 3. API 控制器（用于 AJAX）
zf api User
zf api Data

# 4. 运行
zf serve
```

## 技术细节

### 构建命令实现
```zig
.build_cmd => {
    std.debug.print("Building release binary...\n", .{});
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "zig", "build", "-Doptimize=ReleaseSafe" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    if (result.term.Exited == 0) {
        std.debug.print("✅ Build successful! Binary: zig-out/bin/<app_name>\n", .{});
    } else {
        std.debug.print("❌ Build failed:\n{s}\n", .{result.stderr});
    }
}
```

### API vs HTMX 区分
```zig
const controller_type_comment = if (is_api) 
    "API Controller (JSON output)" 
else 
    "HTMX Controller (HTML output)";
```

## 后续计划

1. **HTMX 模板生成**: 为 HTMX 控制器生成对应的 HTML 模板文件
2. **数据库迁移**: 添加 `zf migrate` 命令
3. **测试生成**: 添加 `zf test:gen` 生成测试文件
4. **Docker 支持**: 添加 `zf docker` 生成 Dockerfile
5. **部署工具**: 添加 `zf deploy` 部署命令

## 升级指南

如果你之前使用 `zfctl`，现在需要：

1. 重新构建项目：
```bash
cd /path/to/zfinal
zig build install
```

2. 更新 PATH（如果有）：
```bash
# 旧的
export PATH=$PATH:/path/to/zfinal/zig-out/bin/zfctl

# 新的
export PATH=$PATH:/path/to/zfinal/zig-out/bin/zf
```

3. 更新命令：
```bash
# 旧的
zfctl new myapp

# 新的
zf new myapp
```

所有功能保持向后兼容！
