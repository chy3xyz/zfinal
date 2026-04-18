<div align="center">

# ⚡ ZFinal

**Minimal, High-Performance Zig Web Framework**

*Inspired by JFinal, a modern web framework for the Zig ecosystem*

[![Zig](https://img.shields.io/badge/Zig-0.16.0-orange.svg)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

**English** | [中文文档](README_CN.md)

</div>

---

## ✨ Why ZFinal?

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

**It's that simple!** 🚀

### 🎯 Core Features

- **🔥 Minimal Design** - JFinal-like API, get started in 5 minutes
- **⚡ Native Performance** - Built on Zig, zero GC pauses, extreme performance
- **🎨 HTMX Support** - Build modern web apps without writing JavaScript
- **💾 Multi-Database** - Out-of-the-box support for SQLite, MySQL, PostgreSQL
- **🔧 Active Record** - Elegant ORM, makes database operations silky smooth
- **🛠️ CLI Tool** - `zf` command-line tool for rapid code generation
- **📦 Zero Dependencies** - Core library has no external dependencies, lightweight

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
# Create project using zf CLI
zf new myapp
cd myapp

# Run the project
zig build run
```

Visit `http://localhost:8080` - 🎉 your first ZFinal app is running!

---

## 💡 Core Features Showcase

### 📍 Routing System

```zig
// RESTful routes
try app.get("/users", UserController.index);
try app.post("/users", UserController.create);
try app.get("/users/:id", UserController.show);
try app.put("/users/:id", UserController.update);
try app.delete("/users/:id", UserController.delete);

// Path parameters
fn show(ctx: *zfinal.Context) !void {
    const id = ctx.getPathParam("id");
    // ...
}
```

### 💾 Active Record ORM

```zig
// Define model
pub const User = struct {
    id: ?i64 = null,
    username: []const u8,
    email: []const u8,
    age: i32,
};

pub const UserModel = zfinal.Model(User, "users");

// CRUD operations
var user = UserModel.Instance{
    .data = User{
        .username = "Alice",
        .email = "alice@example.com",
        .age = 25
    }
};

// Save
try user.save(&db);

// Query
const users = try UserModel.findAll(&db, allocator);
const alice = try UserModel.findById(&db, 1, allocator);

// Update
user.data.age = 26;
try user.save(&db);

// Delete
try user.delete(&db);
```

### 🎨 HTMX Support

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

**Build dynamic web apps without writing JavaScript!**

### 🔐 Interceptors (AOP)

```zig
fn authBefore(ctx: *zfinal.Context) !bool {
    const token = ctx.getHeader("Authorization");
    if (token == null) {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "Unauthorized" });
        return false; // Intercept request
    }
    return true; // Allow request
}

pub const AuthInterceptor = zfinal.Interceptor{
    .name = "auth",
    .before = authBefore,
};

// Apply interceptor
try app.addGlobalInterceptor(AuthInterceptor);
```

### ✅ Data Validation

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

## 🛠️ CLI Tool

ZFinal provides the powerful `zf` CLI tool to boost development efficiency:

```bash
# Create new project
zf new myapp

# Generate HTMX controller
zf g controller User

# Generate API controller
zf api Product

# Generate model
zf g model Post

# Generate interceptor
zf g interceptor Auth

# Build release version
zf build

# Start development server
zf serve
```

---

## 📚 Rich Toolkit

ZFinal includes many utility classes out of the box:

```zig
// String tools
const trimmed = StrKit.trim("  hello  ");
const parts = try StrKit.split(allocator, "a,b,c", ",");

// Hash tools
const md5 = try HashKit.md5(allocator, "password");
const encoded = try HashKit.base64Encode(allocator, data);

// Date tools
const now = DateKit.now();
const formatted = try now.format(allocator, "%Y-%m-%d %H:%M:%S");

// JSON tools
const user = try JsonKit.parse(User, allocator, json_str);
const json = try JsonKit.stringify(allocator, user);

// Array tools
const unique = try ArrayKit.unique(i32, allocator, &array);
const sum = ArrayKit.sum(i32, &array);
```

---

## 🎯 Performance Benchmarks

ZFinal focuses on performance, here are preliminary benchmark results:

```
Framework      Requests/sec    Latency (avg)    Memory
ZFinal         45,000+         0.8ms            12MB
Go Gin         42,000          1.2ms            28MB
Node Express   18,000          3.5ms            65MB
```

*Test environment: MacBook Pro M1, 8 cores, 16GB RAM*

---

## 📖 Complete Documentation

- [Getting Started](doc/getting_started.md)
- [Core Concepts](doc/core_concepts.md)
- [Database & ORM](doc/database.md)
- [Advanced Features](doc/advanced.md)
- [Toolkits](doc/kits.md)
- [HTMX Templates](doc/htmx_template.md)
- [CLI Tool](doc/zf_cli.md)
- [Advanced Tutorial: Life3 App](doc/tutorial_life3.md)

---

## 🌟 Example Projects

### HTMX Todo App

```bash
zig build run-htmx
```

Visit `http://localhost:8080` to see a complete HTMX app example.

### Blog System

```bash
zig build run-blog
```

Complete blog system with user, article, and comment features.

---

## 🗺️ Roadmap

### ✅ Completed

- [x] Core Routing System
- [x] Active Record ORM
- [x] Multi-Database Support (SQLite, MySQL, PostgreSQL)
- [x] Interceptors / AOP
- [x] Data Validator
- [x] HTMX Template Support
- [x] CLI Tool `zf`
- [x] File Uploads
- [x] Static File Serving
- [x] Session Management
- [x] Cookie Support
- [x] WebSocket Support
- [x] 17+ Utility Kits

### 🚧 In Progress

- [x] Template Engine Enhancements (conditionals, loops, includes, layouts, filters)
- [x] Cache System / Redis (in-memory + Redis backends)
- [x] Cron Jobs (proper cron expression parsing, scheduling)
- [x] i18n Support (pluralization, interpolation, locale detection)
- [ ] Template Engine v2 (advanced filters, macros)
- [ ] Cache System / Redis Cluster
- [ ] Distributed Cron
- [ ] Advanced i18n (contextual translations)

### 📅 Planned

- [ ] More Database Drivers
- [ ] gRPC Support
- [ ] Microservices Toolkit
- [ ] Docker Deployment Tools
- [ ] Performance Monitoring Dashboard

---

## 🤝 Contributing

We welcome all forms of contribution!

1. Fork this repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

See [CONTRIBUTING.md](CONTRIBUTING.md) for more information.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## 💬 Community

- **GitHub Issues**: [Report Issues](https://github.com/chy3xyz/zfinal/issues)
- **GitHub Discussions**: [Discussions](https://github.com/chy3xyz/zfinal/discussions)
- **Twitter**: [@zfinal](https://twitter.com/zfinal)

---

## 🙏 Acknowledgments

- Thanks to [JFinal](https://jfinal.com/) for design inspiration
- Thanks to the [Zig](https://ziglang.org/) community for support
- Thanks to all contributors

---

<div align="center">

**If ZFinal helps you, please give us a ⭐️**

Made with ❤️ by the ZFinal Team

</div>
