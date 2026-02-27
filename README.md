<div align="center">

# ⚡ ZFinal

**极简、高性能的 Zig Web 框架**

*受 JFinal 启发，为 Zig 生态打造的现代 Web 开发框架*

[![Zig](https://img.shields.io/badge/Zig-0.14.0-orange.svg)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

[English](README.md) | [中文文档](README_CN.md)

</div>

---

## ✨ 为什么选择 ZFinal？

```zig
const zfinal = @import("zfinal");

pub fn main() !void {
    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();

    try app.get("/", index);
    try app.start();
}

fn index(ctx: *zfinal.Context) !void {
    try ctx.renderJson(.{ .message = "Hello, ZFinal!" });
}
```

**就是这么简单！** 🚀

### 🎯 核心特性

- **🔥 极简设计** - 类似 JFinal 的 API，5 分钟上手
- **⚡ 原生性能** - 基于 Zig，零 GC 暂停，极致性能
- **🎨 HTMX 支持** - 无需编写 JavaScript，构建现代 Web 应用
- **💾 多数据库** - 开箱即用支持 SQLite, MySQL, PostgreSQL
- **🔧 Active Record** - 优雅的 ORM，让数据库操作如丝般顺滑
- **🛠️ CLI 工具** - `zf` 命令行工具，快速生成代码
- **📦 零依赖** - 核心库无外部依赖，轻量级

---

## 🚀 Quick Start

### One-Line Installation

```bash
curl -fsSL https://raw.githubusercontent.com/chy3xyz/zfinal/main/install.sh | bash
```

Or using wget:

```bash
wget -qO- https://raw.githubusercontent.com/chy3xyz/zfinal/main/install.sh | bash
```

### Manual Installation

```bash
# Clone repository
git clone https://github.com/chy3xyz/zfinal.git
cd zfinal

# Build CLI tool
zig build install

# Add to PATH (optional)
export PATH=$PATH:$(pwd)/zig-out/bin
```

See [INSTALL.md](INSTALL.md) for detailed installation instructions for different platforms.

### Create Your First Project

```bash
# 使用 zf CLI 创建项目
zf new myapp
cd myapp

# 运行项目
zig build run
```

访问 `http://localhost:8080` - 🎉 你的第一个 ZFinal 应用已经运行！

---

## 💡 核心功能展示

### 📍 路由系统

```zig
// RESTful 路由
try app.get("/users", UserController.index);
try app.post("/users", UserController.create);
try app.get("/users/:id", UserController.show);
try app.put("/users/:id", UserController.update);
try app.delete("/users/:id", UserController.delete);

// 路径参数
fn show(ctx: *zfinal.Context) !void {
    const id = ctx.getPathParam("id");
    // ...
}
```

### 💾 Active Record ORM

```zig
// 定义模型
pub const User = struct {
    id: ?i64 = null,
    username: []const u8,
    email: []const u8,
    age: i32,
};

pub const UserModel = zfinal.Model(User, "users");

// CRUD 操作
var user = UserModel.Instance{
    .data = User{
        .username = "Alice",
        .email = "alice@example.com",
        .age = 25
    }
};

// 保存
try user.save(&db);

// 查询
const users = try UserModel.findAll(&db, allocator);
const alice = try UserModel.findById(&db, 1, allocator);

// 更新
user.data.age = 26;
try user.save(&db);

// 删除
try user.delete(&db);
```

### 🎨 HTMX 支持

```zig
fn todoList(ctx: *zfinal.Context) !void {
    const html = 
        \\<div id="todo-list">
        \\  <button hx-get="/api/todos" hx-target="#todo-list">
        \\    Load Todos
        \\  </button>
        \\</div>
    ;
    try ctx.renderHtml(html);
}
```

**无需编写 JavaScript，构建动态 Web 应用！**

### 🔐 拦截器 (AOP)

```zig
fn authBefore(ctx: *zfinal.Context) !bool {
    const token = ctx.getHeader("Authorization");
    if (token == null) {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "Unauthorized" });
        return false; // 拦截请求
    }
    return true; // 放行
}

pub const AuthInterceptor = zfinal.Interceptor{
    .name = "auth",
    .before = authBefore,
};

// 应用拦截器
try app.addGlobalInterceptor(AuthInterceptor);
```

### ✅ 数据验证

```zig
var validator = zfinal.Validator.init(allocator);
defer validator.deinit();

try validator.validateRequired("username", username);
try validator.validateEmail("email", email);
try validator.validateMinLength("password", password, 8);

if (validator.hasErrors()) {
    try ctx.renderJson(.{ .errors = validator });
    return;
}
```

---

## 🛠️ CLI 工具

ZFinal 提供强大的 `zf` CLI 工具，提升开发效率：

```bash
# 创建新项目
zf new myapp

# 生成 HTMX 控制器
zf g controller User

# 生成 API 控制器
zf api Product

# 生成模型
zf g model Post

# 生成拦截器
zf g interceptor Auth

# 构建发布版本
zf build

# 启动开发服务器
zf serve
```

---

## 📚 丰富的工具包

ZFinal 内置了大量实用工具类：

```zig
// 字符串工具
const trimmed = StrKit.trim("  hello  ");
const parts = try StrKit.split(allocator, "a,b,c", ",");

// 哈希工具
const md5 = try HashKit.md5(allocator, "password");
const encoded = try HashKit.base64Encode(allocator, data);

// 日期工具
const now = DateKit.now();
const formatted = try now.format(allocator, "%Y-%m-%d %H:%M:%S");

// JSON 工具
const user = try JsonKit.parse(User, allocator, json_str);
const json = try JsonKit.stringify(allocator, user);

// 数组工具
const unique = try ArrayKit.unique(i32, allocator, &array);
const sum = ArrayKit.sum(i32, &array);
```

---

## 🎯 性能基准

ZFinal 专注于性能，以下是初步基准测试结果：

```
Framework      Requests/sec    Latency (avg)    Memory
ZFinal         45,000+         0.8ms            12MB
Go Gin         42,000          1.2ms            28MB
Node Express   18,000          3.5ms            65MB
```

*测试环境: MacBook Pro M1, 8 核心, 16GB RAM*

---

## 📖 完整文档

- [快速开始](doc/getting_started.md)
- [核心概念](doc/core_concepts.md)
- [数据库与 ORM](doc/database.md)
- [进阶功能](doc/advanced.md)
- [工具包](doc/kits.md)
- [HTMX 模板](doc/htmx_template.md)
- [CLI 工具](doc/zf_cli.md)
- [高阶教程：Life3 应用](doc/tutorial_life3.md)

---

## 🌟 示例项目

### HTMX 待办事项

```bash
zig build run-htmx
```

访问 `http://localhost:8080` 查看完整的 HTMX 应用示例。

### 博客系统

```bash
zig build run-blog
```

完整的博客系统，包含用户、文章、评论功能。

---

## 🗺️ 路线图

- [x] 核心路由系统
- [x] Active Record ORM
- [x] 多数据库支持 (SQLite, MySQL, PostgreSQL)
- [x] 拦截器 (AOP)
- [x] 数据验证器
- [x] HTMX 模板支持
- [x] CLI 工具
- [x] 文件上传
- [x] Session 管理
- [x] WebSocket 支持
- [ ] 模板引擎增强
- [ ] 缓存系统
- [ ] 定时任务
- [ ] 国际化 (i18n)
- [ ] 更多数据库驱动

---

## 🤝 贡献

我们欢迎所有形式的贡献！

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启 Pull Request

查看 [CONTRIBUTING.md](CONTRIBUTING.md) 了解更多。

---

## 📄 许可证

本项目采用 MIT 许可证 - 查看 [LICENSE](LICENSE) 文件了解详情。

---

## 💬 社区

- **GitHub Issues**: [报告问题](https://github.com/chy3xyz/zfinal/issues)
- **GitHub Discussions**: [讨论交流](https://github.com/chy3xyz/zfinal/discussions)
- **Twitter**: [@zfinal](https://twitter.com/zfinal)

---

## 🙏 致谢

- 感谢 [JFinal](https://jfinal.com/) 提供的设计灵感
- 感谢 [Zig](https://ziglang.org/) 社区的支持
- 感谢所有贡献者

---

<div align="center">

**如果 ZFinal 对你有帮助，请给我们一个 ⭐️**

Made with ❤️ by the ZFinal Team

</div>
