# AGENTS.md - ZFinal Development Guide

This file provides guidance for AI agents working on the ZFinal project.

## Project Overview

ZFinal is a high-performance Zig web framework inspired by JFinal. It provides a minimalist API for building web applications with zero GC pauses and极致性能.

**Zig Version**: 0.14.0+  
**License**: MIT  
**Repository**: https://github.com/chy3xyz/zfinal

---

## Build & Test Commands

### Running Tests

```bash
# Run all unit tests
zig build test

# Run tests with verbose output
zig build test --summary all
```

### Running Examples/Demos

```bash
# Hello World demo (basic routing, JSON, cookies)
zig build run-demo

# Blog demo (full CRUD, database, session)
zig build run-blog

# HTMX demo (server-side rendering, SPA-like UX)
zig build run-htmx

# WebSocket demo
zig build run-ws-demo

# Single-file blog app
zig build run-blog-app

# Edge computing demo
zig build run-edge

# PocketBase Lite demo
zig build run-pb

# CLI tool
zig build install
```

### Building

```bash
# Build release version
zig build -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseFast

# Build with specific database support
zig build -Dpostgres=true -Dmysql=true -Dsqlite=true

# Install CLI tool
zig build install
```

---

## Code Style Guidelines

### General Principles

- Follow [Zig's official style guide](https://ziglang.org/documentation/master/#Style-Guide)
- Write small, focused functions
- Use meaningful variable and function names
- Add comments for complex logic
- Keep functions under 50 lines when possible
- End all files with a newline

### Imports

```zig
// Standard import at the top of every file
const std = @import("std");

// Local imports use relative paths
const Context = @import("context.zig");
const Params = @import("params.zig");
```

### Error Handling

- Use `!void` or `!T` for functions that can fail
- Always handle errors with `try` or `catch`
- Propagate errors up the call stack when appropriate

```zig
pub fn myHandler(ctx: *Context) !void {
    // Use try for functions that return error unions
    try ctx.renderJson(.{ .status = "ok" });
    
    // For optional handling
    const value = ctx.getPara("name") catch null;
}
```

### Naming Conventions

- **Functions**: `camelCase` (e.g., `getHeader`, `parseQuery`)
- **Types/Structs**: `PascalCase` (e.g., `Context`, `ConnectionPool`)
- **Constants**: `PascalCase` for typed constants, `SCREAMING_SNAKE` for enum values
- **Variables**: `camelCase` (e.g., `allocator`, `queryParams`)
- **Files**: `snake_case.zig` (e.g., `context.zig`, `http_kit.zig`)

### Structs and Types

```zig
// Public struct with type inference
pub const MyStruct = struct {
    name: []const u8,
    value: i32,
    
    // Associated functions go inside
    pub fn init(name: []const u8, value: i32) MyStruct {
        return .{ .name = name, .value = value };
    }
    
    pub fn deinit(self: *MyStruct) void {
        // cleanup
    }
};
```

### Testing

Tests are defined inline within each module:

```zig
test "my test name" {
    const result = myFunction();
    try std.testing.expectEqual(expected, result);
}
```

- Test names should be descriptive: `test "validator email validation"`
- Place tests at the bottom of the file or in a dedicated test block
- Use `std.testing.expectEqual`, `expect`, etc.

### Module Organization

```
src/
├── main.zig          # Public API exports
├── core/             # Core framework (router, context, server)
├── db/               # Database, ORM, connection pools
├── kit/              # Utility kits (str_kit, hash_kit, etc.)
├── interceptor/      # Interceptor (AOP) support
├── validator/        # Input validation
├── plugin/           # Plugin system
├── template/         # Template rendering
├── websocket/        # WebSocket support
├── upload/           # File upload handling
└── ...
```

### Conventions

1. **Allocation**: Always use the allocator passed to functions
2. **Cleanup**: Use `defer` for cleanup, especially for `deinit()` calls
3. **Optionals**: Use `?T` for optional types, `orelse` for default values
4. **Slices**: Prefer `[]const u8` for read-only strings, `[]u8` when modifying
5. **Hash Maps**: Use `std.StringHashMap` for string-keyed maps

---

## Common Patterns

### Handler Functions

```zig
// Standard handler signature
fn myHandler(ctx: *zfinal.Context) !void {
    // Get query parameters
    const name = try ctx.getParaDefault("name", "Guest");
    
    // Return JSON response
    try ctx.renderJson(.{ .greeting = "Hello, {s}!" });
    
    // Or return text/HTML
    try ctx.renderText("Hello!");
    try ctx.renderHtml("<p>Hello!</p>");
}
```

### Adding Routes

```zig
var app = zfinal.ZFinal.init(allocator);
defer app.deinit();

try app.get("/path", handler);
try app.post("/path", handler);
try app.addRoute("/api/:id", handler);
```

### Database Operations

```zig
// Use connection pool
var pool = try zfinal.ConnectionPool.init(allocator, config);
defer pool.deinit();

const conn = try pool.getConnection();
defer conn.release();

// Execute queries
const result = try conn.exec("SELECT * FROM users");
```

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `src/main.zig` | Public API exports |
| `src/core/zfinal.zig` | Main ZFinal app |
| `src/core/context.zig` | HTTP request/response context |
| `src/core/router.zig` | Routing logic |
| `src/db/model.zig` | Active Record ORM |
| `src/db/pool.zig` | Database connection pool |

---

## Contributing

1. Fork the repo and create a feature branch
2. Follow Zig style guide
3. Add tests for new functionality
4. Update documentation
5. Run `zig build test` before submitting PR

---

## Useful Resources

- [Zig Documentation](https://ziglang.org/documentation/master/)
- [Zig Standard Library](https://pkg.zig.std/)
- [Zig Style Guide](https://ziglang.org/documentation/master/#Style-Guide)
