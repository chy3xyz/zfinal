<div align="center">

# ⚡ ZFinal

**极简、高性能的 Zig Web 框架**

*受 JFinal 启发，为 Zig 生态打造的现代 Web 开发框架*

[![Zig](https://img.shields.io/badge/Zig-0.16.0-orange.svg)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

[English](README.md) | **中文文档**

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
    try ctx.renderJson(.{ .message = "你好，ZFinal！" });
}
```

**就是这么简单！** 🚀

### 🎯 核心特性

- **🔥 极简设计** - 类似 JFinal 的 API，5 分钟上手，让 Java 开发者倍感亲切
- **⚡ 原生性能** - 基于 Zig，零 GC 暂停，内存安全，性能爆表
- **🎨 HTMX 支持** - 无需编写 JavaScript，轻松构建现代动态 Web 应用
- **💾 多数据库** - 开箱即用支持 SQLite, MySQL, PostgreSQL
- **🔧 Active Record** - 优雅的 ORM，让数据库操作如丝般顺滑
- **🛠️ CLI 工具** - 强大的 `zf` 命令行工具，快速生成代码脚手架
- **📦 零依赖** - 核心库无外部依赖，轻量级，易部署

---

## 🚀 快速开始

### 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/chy3xyz/zfinal/main/install.sh | bash
```

或使用 wget:

```bash
wget -qO- https://raw.githubusercontent.com/chy3xyz/zfinal/main/install.sh | bash
```

### 手动安装

```bash
# 克隆仓库
git clone https://github.com/chy3xyz/zfinal.git
cd zfinal

# 构建 CLI 工具
zig build install

# 添加到 PATH (可选)
export PATH=$PATH:$(pwd)/zig-out/bin
```

查看 [INSTALL.md](INSTALL.md) 了解不同平台的详细安装说明。

### 创建第一个项目

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

支持 RESTful 风格的路由定义，简洁明了：

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
    try ctx.renderJson(.{ .id = id });
}
```

### 💾 Active Record ORM

优雅的 ORM 设计，让数据库操作变得简单：

```zig
// 定义模型
pub const User = struct {
    id: ?i64 = null,
    username: []const u8,
    email: []const u8,
    age: i32,
};

pub const UserModel = zfinal.Model(User, "users");

// 创建
var user = UserModel.Instance{
    .data = User{
        .username = "张三",
        .email = "zhangsan@example.com",
        .age = 25
    }
};
try user.save(&db);

// 查询
const users = try UserModel.findAll(&db, allocator);
const user1 = try UserModel.findById(&db, 1, allocator);
const adults = try UserModel.findWhere(&db, "age >= 18", allocator);

// 分页
const page = try UserModel.paginate(&db, 1, 10, allocator);

// 更新
user.data.age = 26;
try user.save(&db);

// 删除
try user.delete(&db);
```

### 🎨 HTMX 支持

无需编写 JavaScript，构建现代动态 Web 应用：

```zig
fn todoList(ctx: *zfinal.Context) !void {
    const html = 
        \\<div id="todo-list">
        \\  <button hx-get="/api/todos" 
        \\          hx-target="#todo-list"
        \\          hx-swap="innerHTML">
        \\    加载待办事项
        \\  </button>
        \\</div>
    ;
    try ctx.renderHtml(html);
}

fn getTodos(ctx: *zfinal.Context) !void {
    // 返回 HTML 片段，HTMX 自动更新页面
    try ctx.renderHtml("<ul><li>学习 Zig</li><li>使用 ZFinal</li></ul>");
}
```

### 🔐 拦截器 (AOP)

强大的 AOP 支持，轻松实现权限控制、日志记录等：

```zig
fn authBefore(ctx: *zfinal.Context) !bool {
    const token = ctx.getHeader("Authorization");
    if (token == null) {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "未授权访问" });
        return false; // 拦截请求
    }
    return true; // 放行
}

pub const AuthInterceptor = zfinal.Interceptor{
    .name = "auth",
    .before = authBefore,
};

// 全局拦截器
try app.addGlobalInterceptor(AuthInterceptor);

// 路由级拦截器
try app.getWithInterceptors("/admin", AdminController.index, &.{AuthInterceptor});
```

### ✅ 数据验证

内置强大的验证器，保证数据质量：

```zig
var validator = zfinal.Validator.init(allocator);
defer validator.deinit();

try validator.validateRequired("username", username);
try validator.validateEmail("email", email);
try validator.validateMinLength("password", password, 8);
try validator.validateRange("age", age, 18, 100);

if (validator.hasErrors()) {
    ctx.res_status = .bad_request;
    try ctx.renderJson(.{ .errors = validator });
    return;
}
```

---

## 🛠️ CLI 工具

ZFinal 提供强大的 `zf` CLI 工具，极大提升开发效率：

```bash
# 创建新项目
zf new myapp

# 生成 HTMX 控制器（用于页面渲染）
zf g controller User

# 生成 API 控制器（用于 JSON API）
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

ZFinal 内置了大量实用工具类，开箱即用：

### 字符串工具 (StrKit)
```zig
const trimmed = StrKit.trim("  你好  ");
const parts = try StrKit.split(allocator, "a,b,c", ",");
const upper = try StrKit.toUpper(allocator, "hello");
```

### 哈希工具 (HashKit)
```zig
const md5 = try HashKit.md5(allocator, "密码");
const sha256 = try HashKit.sha256(allocator, "文本");
const encoded = try HashKit.base64Encode(allocator, data);
```

### 日期工具 (DateKit)
```zig
const now = DateKit.now();
const formatted = try now.format(allocator, "%Y年%m月%d日 %H:%M:%S");
const isLeap = DateKit.isLeapYear(2024);
```

### JSON 工具 (JsonKit)
```zig
const user = try JsonKit.parse(User, allocator, json_str);
const json = try JsonKit.stringify(allocator, user);
const pretty = try JsonKit.prettify(allocator, user);
```

### 数组工具 (ArrayKit)
```zig
const unique = try ArrayKit.unique(i32, allocator, &array);
const sum = ArrayKit.sum(i32, &array);
const max = ArrayKit.max(i32, &array);
```

还有更多：**FormatKit**, **FileKit**, **HttpKit**, **SysKit**, **TimeKit**, **RegexKit** 等...

---

## 🎯 性能基准

ZFinal 专注于性能，以下是初步基准测试结果：

```
框架           请求/秒      平均延迟      内存占用
ZFinal         45,000+      0.8ms        12MB
Go Gin         42,000       1.2ms        28MB
Node Express   18,000       3.5ms        65MB
Python Flask   8,000        8.2ms        95MB
```

*测试环境: MacBook Pro M1, 8 核心, 16GB RAM*

---

## 📖 完整文档

- [ZF CLI 工具](doc/zf_cli.md) - 命令行工具完整指南
- [快速开始](doc/getting_started.md) - 5 分钟上手教程
- [核心概念](doc/core_concepts.md) - 路由、控制器、上下文
- [数据库与 ORM](doc/database.md) - Active Record 使用指南
- [进阶功能](doc/advanced.md) - 拦截器、验证器、文件上传
- [工具包](doc/kits.md) - 17 个实用工具类详解
- [HTMX 模板](doc/htmx_template.md) - 无 JS 的现代 Web 开发
- [高阶教程：Life3 应用](doc/tutorial_life3.md) - 完整项目实战

---

## 🌟 示例项目

### HTMX 待办事项

完整的 HTMX 应用示例，展示无 JavaScript 的动态 Web 开发：

```bash
zig build run-htmx
```

访问 `http://localhost:8080` 体验 HTMX 的魅力。

### 博客系统

功能完整的博客系统，包含用户、文章、评论、标签等功能：

```bash
zig build run-blog
```

展示了 ZFinal 的完整能力：ORM、验证器、拦截器、文件上传等。

---

## 🗺️ 开发路线图

### ✅ 已完成

- [x] 核心路由系统
- [x] Active Record ORM
- [x] 多数据库支持 (SQLite, MySQL, PostgreSQL)
- [x] 拦截器 (AOP)
- [x] 数据验证器
- [x] HTMX 模板支持
- [x] CLI 工具 (zf)
- [x] 文件上传
- [x] 静态文件服务
- [x] Session 管理
- [x] Cookie 支持
- [x] WebSocket 支持
- [x] 17+ 实用工具包

### 🚧 进行中

- [ ] 模板引擎增强
- [ ] 缓存系统 (Redis 支持)
- [ ] 定时任务 (Cron)
- [ ] 国际化 (i18n)

### 📅 计划中

- [ ] 更多数据库驱动
- [ ] gRPC 支持
- [ ] 微服务工具包
- [ ] Docker 部署工具
- [ ] 性能监控面板

---

## 🤝 贡献

我们热烈欢迎各种形式的贡献！无论是：

- 🐛 报告 Bug
- 💡 提出新功能建议
- 📝 改进文档
- 🔧 提交代码

都请随时参与！

### 贡献步骤

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m '添加某个很棒的功能'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启 Pull Request

查看 [CONTRIBUTING.md](CONTRIBUTING.md) 了解更多贡献指南。

---

## 📄 许可证

本项目采用 MIT 许可证 - 查看 [LICENSE](LICENSE) 文件了解详情。

---

## 💬 社区与支持

- **GitHub Issues**: [报告问题](https://github.com/chy3xyz/zfinal/issues)
- **GitHub Discussions**: [讨论交流](https://github.com/chy3xyz/zfinal/discussions)


---

## 🙏 致谢

- 感谢 [JFinal](https://jfinal.com/) 提供的优秀设计理念
- 感谢 [Zig](https://ziglang.org/) 语言及其社区
- 感谢 [HTMX](https://htmx.org/) 带来的现代 Web 开发新思路
- 感谢所有贡献者的辛勤付出

---

## 🌟 Star History

如果 ZFinal 对你有帮助，请不要吝啬你的 Star ⭐️

这将是对我们最大的鼓励！

---

<div align="center">

**用 Zig 构建，为速度而生**

Made with ❤️ by the ZFinal Team

[官网](https://zfinal.dev) | [文档](https://docs.zfinal.dev) | [示例](https://examples.zfinal.dev)

</div>
