---
name: zfinal-app
description: Build full-stack web applications with ZFinal framework. Generate handlers, models, interceptors, database schemas, and complete CRUD endpoints following ZFinal best practices. Use when user asks to build a web app, API, or website with Zig/ZFinal.
---

# ZFinal Application Builder

You are an expert ZFinal developer. Follow these rules when building ZFinal applications.

## Framework Capabilities

ZFinal provides:
- **Fiber-based async HTTP server** (kqueue/io_uring, keep-alive, zero heap per connection)
- **ActiveRecord ORM** (SQLite/PostgreSQL/MySQL, parameterized queries, connection pooling)
- **CSRF protection** (single-use tokens, auto-expiry, interceptor)
- **Structured logging** (compile-time levels, key=value fields, stderr/writer backends)
- **Template engine** (variables, loops, conditions, includes, extends, layouts)
- **17 utility kits** (validation, hashing, JSON, file I/O, random/CSPRNG, etc.)
- **Health endpoint** + **Metrics** (uptime, request counters, error ring buffer)
- **Graceful shutdown** (SIGTERM/SIGINT handling)

## Project Scaffold

When creating a new ZFinal project, generate this structure:

```
myapp/
├── build.zig           # Import zfinal as dependency
├── build.zig.zon       # Package manifest  
├── src/
│   ├── main.zig        # App entry: init, routes, interceptors, start
│   ├── controller/     # Route handlers (one file per resource)
│   ├── model/          # ActiveRecord model definitions
│   ├── interceptor/    # Custom interceptors
│   └── config/         # DB config, route registration
└── templates/          # HTML templates (if using HTMX)
```

## build.zig Template

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "APP_NAME",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    const zfinal_path = "PATH_TO_ZFINAL"; // User must set this
    const zfinal_mod = b.addModule("zfinal", .{
        .root_source_file = b.path(zfinal_path ++ "/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    zfinal_mod.link_libc = true;
    zfinal_mod.linkSystemLibrary("sqlite3", .{});
    exe.root_module.addImport("zfinal", zfinal_mod);

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
```

## Handler Patterns

### JSON API Handler
```zig
fn listUsers(ctx: *zfinal.Context) !void {
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    
    var result = try UserModel.findAll(db, ctx.allocator);
    defer ctx.allocator.free(result);
    
    try ctx.renderJson(.{ .users = result });
}
```

### Form Handler with Validation
```zig
fn createUser(ctx: *zfinal.Context) !void {
    // CSRF check
    const token = try ctx.getPara("csrf_token") orelse {
        ctx.res_status = .forbidden;
        return try ctx.renderJson(.{ .err = "Missing CSRF token" });
    };
    if (!try tokenMgr.validate(token)) {
        ctx.res_status = .forbidden;
        return try ctx.renderJson(.{ .err = "Invalid CSRF token" });
    }
    // Validate input
    const name = try ctx.getPara("name") orelse {
        ctx.res_status = .bad_request;
        return try ctx.renderJson(.{ .err = "Name is required" });
    };
    // Save to database...
}
```

## Model Pattern

```zig
const User = struct {
    id: ?i64 = null,
    name: []const u8,
    email: []const u8,
    created_at: []const u8,
};
const UserModel = zfinal.Model(User, "users");
```

## Interceptor Pattern

```zig
fn authBefore(ctx: *zfinal.Context) !bool {
    const token = ctx.getHeader("Authorization");
    if (token == null) {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .err = "Unauthorized" });
        return false;
    }
    return true;
}

pub const AuthInterceptor = zfinal.Interceptor{
    .name = "auth",
    .before = authBefore,
};
```

## Quality Checklist

Before delivering code, verify:
- [ ] Every `init()` has matching `defer deinit()`
- [ ] SQL uses parameterized queries (`execParams`/`queryParams`), never string concatenation
- [ ] State-changing routes (POST/PUT/DELETE) have CSRF protection
- [ ] All user input validated with Validator or manual checks
- [ ] Logger used instead of std.debug.print
- [ ] Remote address used for rate limiting (not proxy headers unless explicitly trusted)
- [ ] max_body_size set for file upload endpoints
- [ ] Health endpoint registered at `/health`
- [ ] Graceful shutdown registered with `shutdown.registerHandlers()`
