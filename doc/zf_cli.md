# ZF CLI 工具

`zf` 是 ZFinal 框架的命令行工具，用于快速创建项目和生成代码。

## 安装

```bash
cd /path/to/zfinal
zig build install

# 将 zf 添加到 PATH (可选)
export PATH=$PATH:/path/to/zfinal/zig-out/bin
```

## 命令列表

### 1. new - 创建新项目

创建一个新的 ZFinal 项目，包含完整的目录结构和配置文件。

```bash
zf new <project_name>
```

**示例:**
```bash
zf new myapp
cd myapp
zig build run
```

生成的项目结构：
```
myapp/
├── build.zig
├── build.zig.zon
└── src/
    ├── main.zig
    ├── config/
    │   ├── config.zig
    │   ├── routes.zig
    │   └── db_init.zig
    ├── controller/
    │   └── index_controller.zig
    ├── model/
    │   └── user.zig
    └── interceptor/
        └── interceptors.zig
```

### 2. generate (g) - 生成代码

快速生成 Controller、Model 或 Interceptor 代码。

```bash
zf generate <type> <name>
zf g <type> <name>  # 简写
```

**类型:**
- `controller` - 生成控制器
- `model` - 生成模型
- `interceptor` - 生成拦截器

**示例:**

```bash
# 生成 ProductController
zf g controller Product
# 生成文件: src/controller/product_controller.zig

# 生成 Order 模型
zf g model Order
# 生成文件: src/model/order.zig

# 生成 Auth 拦截器
zf g interceptor Auth
# 生成文件: src/interceptor/auth_interceptor.zig
```

#### 生成的 Controller 示例

```zig
const std = @import("std");
const zfinal = @import("zfinal");

pub const ProductController = struct {
    /// List all Products
    pub fn index(ctx: *zfinal.Context) !void {
        try ctx.renderJson(.{
            .message = "Product list",
            .data = .{},
        });
    }

    /// Show a single Product
    pub fn show(ctx: *zfinal.Context) !void {
        const id = ctx.getPathParam("id") orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing ID" });
            return;
        };

        try ctx.renderJson(.{
            .id = id,
            .message = "Product details",
        });
    }

    /// Create a new Product
    pub fn create(ctx: *zfinal.Context) !void {
        try ctx.renderJson(.{
            .message = "Product created",
        });
    }

    /// Update a Product
    pub fn update(ctx: *zfinal.Context) !void {
        // ...
    }

    /// Delete a Product
    pub fn delete(ctx: *zfinal.Context) !void {
        // ...
    }
};
```

#### 生成的 Model 示例

```zig
const zfinal = @import("zfinal");

pub const Order = struct {
    id: ?i64 = null,
    name: []const u8,
    created_at: ?[]const u8 = null,
};

pub const OrderModel = zfinal.Model(Order, "orders");
```

#### 生成的 Interceptor 示例

```zig
const std = @import("std");
const zfinal = @import("zfinal");

fn authBefore(ctx: *zfinal.Context) !bool {
    std.debug.print("Auth interceptor: before\n", .{});
    return true; // Continue to next interceptor/handler
}

fn authAfter(ctx: *zfinal.Context) !void {
    std.debug.print("Auth interceptor: after\n", .{});
}

pub const AuthInterceptor = zfinal.Interceptor{
    .name = "auth",
    .before = authBefore,
    .after = authAfter,
};
```

### 3. migrate - 数据库迁移

管理数据库迁移文件。

```bash
zf migrate <action> [name]
```

**Actions:**
- `new <name>` - 创建新的迁移文件
- `run` - 运行迁移（暂未实现，请使用手动方式）

**示例:**
```bash
zf migrate new create_users_table
# 生成: migrations/1701580000_create_users_table.sql
```

### 4. test:gen - 生成测试

快速生成测试文件。

```bash
zf test:gen <name>
```

**示例:**
```bash
zf test:gen User
# 生成: test/user_test.zig
```

### 5. docker - Docker 支持

生成 Dockerfile 和 .dockerignore 文件。

```bash
zf docker
```

### 6. deploy - 部署工具

生成或运行部署脚本。

```bash
zf deploy
```
- 首次运行会生成 `deploy.sh` 模板
- 再次运行会执行 `deploy.sh`

### 7. serve (s) - 启动开发服务器

快速启动开发服务器（实际执行 `zig build run`）。

```bash
zf serve
zf s  # 简写
```

### 4. test (t) - 运行测试

运行项目测试（实际执行 `zig build test`）。

```bash
zf test
zf t  # 简写
```

### 5. version (v) - 查看版本

显示 zf 工具的版本信息。

```bash
zf version
zf v  # 简写
```

### 6. help (h) - 帮助信息

显示所有可用命令和使用说明。

```bash
zf help
zf h  # 简写
zf    # 不带参数也会显示帮助
```

## 完整工作流程示例

```bash
# 1. 创建新项目
zf new blog

# 2. 进入项目目录
cd blog

# 3. 生成代码
zf g controller Post
zf g controller Comment
zf g model Post
zf g model Comment
zf g interceptor Auth

# 4. 编辑代码...

# 5. 运行项目
zf serve
# 或者
zig build run

# 6. 运行测试
zf test
# 或者
zig build test
```

## 注意事项

1. **项目目录**: `generate` 命令必须在 ZFinal 项目根目录下执行
2. **命名规范**: 
   - Controller 名称会自动添加 `Controller` 后缀
   - Model 表名会自动添加复数 `s`
   - 文件名会自动转换为小写
3. **覆盖警告**: 生成代码时会覆盖同名文件，请注意备份

## 快捷键

所有命令都支持简写：
- `generate` → `g`
- `serve` → `s`
- `test` → `t`
- `version` → `v`
- `help` → `h`
