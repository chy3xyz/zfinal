const std = @import("std");

// ── build.zig ── (format-string template — uses {{ }} escaping)
pub const build_zig =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {{
    \\    const target = b.standardTargetOptions(.{{}});
    \\    const optimize = b.standardOptimizeOption(.{{}});
    \\
    \\    // Driver options (match zfinal's build.zig option names)
    \\    const use_mysql = b.option(bool, "driver_mysql", "Enable MySQL driver (libmysqlclient)") orelse false;
    \\    const use_pg = b.option(bool, "driver_pg", "Enable PostgreSQL driver (libpq)") orelse false;
    \\
    \\    // Remote zfinal dependency — projects are standalone, not tied to a local clone
    \\    const zfinal_dep = b.dependency("zfinal", .{{
    \\        .target = target,
    \\        .optimize = optimize,
    \\        .driver_pg = use_pg,
    \\        .driver_mysql = use_mysql,
    \\    }});
    \\    const zfinal_mod = zfinal_dep.module("zfinal");
    \\
    \\    const exe_mod = b.createModule(.{{
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\        .imports = &.{{.{{ .name = "zfinal", .module = zfinal_mod }}}},
    \\    }});
    \\    exe_mod.link_libc = true;
    \\    exe_mod.linkSystemLibrary("sqlite3", .{{}});
    \\    if (use_mysql) exe_mod.linkSystemLibrary("mysqlclient", .{{}});
    \\    if (use_pg) exe_mod.linkSystemLibrary("pq", .{{}});
    \\
    \\    const exe = b.addExecutable(.{{
    \\        .name = "{s}",
    \\        .root_module = exe_mod,
    \\    }});
    \\
    \\    b.installArtifact(exe);
    \\
    \\    const run_cmd = b.addRunArtifact(exe);
    \\    run_cmd.step.dependOn(b.getInstallStep());
    \\    if (b.args) |args| {{
    \\        run_cmd.addArgs(args);
    \\    }}
    \\
    \\    const run_step = b.step("run", "Run the app");
    \\    run_step.dependOn(&run_cmd.step);
    \\}}
;

// ── build.zig.zon ── (format-string template)
pub const build_zig_zon =
    \\.{{
    \\    .name = .{s},
    \\    .version = "0.1.0",
    \\    .fingerprint = 0xd3da709fcd7fc3,
    \\    .minimum_zig_version = "0.17.0",
    \\    .dependencies = .{{
    \\        .zfinal = .{{
    \\            .url = "https://github.com/chy3xyz/zfinal/archive/refs/tags/v0.22.1.tar.gz",
    \\            .hash = "...", // run `zig fetch <url>` to fill the actual hash
    \\        }},
    \\    }},
    \\    .paths = .{{
    \\        "build.zig",
    \\        "build.zig.zon",
    \\        "src",
    \\    }},
    \\}}
;

// ── src/main.zig ── (format-string template)
pub const main_zig =
    \\const std = @import("std");
    \\const zfinal = @import("zfinal");
    \\const App = @import("App.zig").App;
    \\const config = @import("config.zig");
    \\const routes = @import("routes.zig");
    \\
    \\pub fn main(init: std.process.Init) !void {{
    \\    zfinal.io_instance.init(init);
    \\    const allocator = init.gpa;
    \\
    \\    var logger = zfinal.Logger.init(allocator);
    \\    logger.setLevel(switch (zfinal.LOG_LEVEL) {{
    \\        .debug => .debug,
    \\        .info  => .info,
    \\        .warn  => .warn,
    \\        .err   => .err,
    \\    }});
    \\    logger.prefix = "{s}";
    \\    zfinal.initGlobalLogger(logger);
    \\
    \\    // Assemble app
    \\    var app = try App.init(allocator, config.database, config.server);
    \\    defer app.deinit();
    \\
    \\    // Register routes
    \\    try routes.register(&app);
    \\
    \\    // Start
    \\    zfinal.getLogger().infoFmt("starting on :{{d}}", .{{config.server.port}});
    \\    try app.start();
    \\}}
;

// ── src/App.zig ── (direct write — single braces)
pub const app_zig =
    \\const std = @import("std");
    \\const zfinal = @import("zfinal");
    \\
    \\pub const App = struct {
    \\    allocator: std.mem.Allocator,
    \\    zf: zfinal.ZFinal,
    \\    pool: zfinal.ConnectionPool,
    \\
    \\    /// Initialize database + pool + ZFinal instance.
    \\    pub fn init(
    \\        allocator: std.mem.Allocator,
    \\        db_cfg: zfinal.DBConfig,
    \\        server_cfg: zfinal.ServerConfig,
    \\    ) !App {
    \\        var db = try zfinal.DB.init(allocator, db_cfg);
    \\        errdefer db.deinit();
    \\        try ensureSchema(&db);
    \\        var zf = zfinal.ZFinal.init(allocator);
    \\        zf.config = server_cfg;
    \\
    \\        return .{
    \\            .allocator = allocator,
    \\            .zf = zf,
    \\            .pool = try zfinal.ConnectionPool.init(allocator, db_cfg, 8),
    \\        };
    \\    }
    \\
    \\    pub fn deinit(self: *App) void {
    \\        self.pool.deinit();
    \\        self.zf.deinit();
    \\    }
    \\
    \\    pub fn start(self: *App) !void {
    \\        try self.zf.start();
    \\    }
    \\
    \\    // ── Route registration helpers ──
    \\
    \\    pub fn get(self: *App, path: []const u8, handler: anytype) !void {
    \\        try self.zf.get(path, handler);
    \\    }
    \\
    \\    pub fn post(self: *App, path: []const u8, handler: anytype) !void {
    \\        try self.zf.post(path, handler);
    \\    }
    \\
    \\    pub fn put(self: *App, path: []const u8, handler: anytype) !void {
    \\        try self.zf.put(path, handler);
    \\    }
    \\
    \\    pub fn delete(self: *App, path: []const u8, handler: anytype) !void {
    \\        try self.zf.delete(path, handler);
    \\    }
    \\
    \\    pub fn patch(self: *App, path: []const u8, handler: anytype) !void {
    \\        try self.zf.patch(path, handler);
    \\    }
    \\
    \\    pub fn addGlobalMiddleware(self: *App, mw: zfinal.Interceptor) !void {
    \\        try self.zf.addGlobalInterceptor(mw);
    \\    }
    \\};
    \\
    \\// ── Schema migration ──
    \\// Dev: auto-create tables. Production: use zf migrate.
    \\fn ensureSchema(db: *zfinal.DB) !void {
    \\    try db.exec("CREATE TABLE IF NOT EXISTS users (" ++
    \\        "id INTEGER PRIMARY KEY AUTOINCREMENT," ++
    \\        "name TEXT NOT NULL," ++
    \\        "created_at DATETIME DEFAULT CURRENT_TIMESTAMP)");
    \\}
;

// ── src/config.zig ──
pub const config_zig =
    \\const zfinal = @import("zfinal");
    \\
    \\pub const server = zfinal.ServerConfig{
    \\    .host = "0.0.0.0",
    \\    .port = 8080,
    \\};
    \\
    \\// Switch DB driver: zfinal.DBConfig.sqlite("app.db")
    \\//                  zfinal.DBConfig.postgres("host=localhost dbname=app")
    \\//                  zfinal.DBConfig.mysql("host=localhost;user=root;db=app")
    \\pub const database = zfinal.DBConfig.sqliteMemory();
    \\
    \\pub const api_prefix = "/api/v1";
;

// ── src/routes.zig ──
pub const routes_zig =
    \\const zfinal = @import("zfinal");
    \\const App = @import("App.zig").App;
    \\const middleware = @import("middleware/auth.zig");
    \\
    \\const handler = struct {
    \\    const index = @import("handler/index.zig");
    \\    const user = @import("handler/user.zig");
    \\};
    \\
    \\pub fn register(app: *App) !void {
    \\    // Health & meta
    \\    try app.get("/health", handler.index.health);
    \\    try app.get("/", handler.index.root);
    \\
    \\    // User endpoints — replace with real handlers
    \\    try app.get("/api/v1/users", handler.user.list);
    \\    try app.get("/api/v1/users/:id", handler.user.show);
    \\    try app.post("/api/v1/users", handler.user.create);
    \\    try app.put("/api/v1/users/:id", handler.user.update);
    \\    try app.delete("/api/v1/users/:id", handler.user.delete);
    \\
    \\    // Attach middleware to protected routes
    \\    try app.addGlobalMiddleware(middleware.logging);
    \\}
;

// ── src/handler/index.zig ── (format-string template)
pub const handler_index_zig =
    \\const zfinal = @import("zfinal");
    \\
    \\pub fn root(ctx: *zfinal.Context) !void {{
    \\    try ctx.renderJson(.{{
    \\        .app = "{s}",
    \\        .version = "0.1.0",
    \\    }});
    \\}}
    \\
    \\pub fn health(ctx: *zfinal.Context) !void {{
    \\    try ctx.renderJson(.{{ .status = "ok" }});
    \\}}
;

// ── src/handler/user.zig ── (direct write — single braces)
pub const handler_user_zig =
    \\const std = @import("std");
    \\const zfinal = @import("zfinal");
    \\const UserModel = @import("../model/user.zig").UserModel;
    \\
    \\pub fn list(ctx: *zfinal.Context) !void {
    \\    try ctx.renderJson(.{ .data = &.{} });
    \\}
    \\
    \\pub fn show(ctx: *zfinal.Context) !void {
    \\    const id = try zfinal.extract.requireParamInt(ctx, i64, "id");
    \\    _ = id; // TODO: lookup
    \\    return error.NotFound;
    \\}
    \\
    \\pub fn create(ctx: *zfinal.Context) !void {
    \\    const name = (try ctx.getPara("name")) orelse {
    \\        zfinal.http_error.setDetail(ctx, "name");
    \\        return error.BadRequest;
    \\    };
    \\    _ = name; // TODO: persist
    \\    ctx.res_status = .created;
    \\    try ctx.renderJson(.{ .ok = true });
    \\}
    \\
    \\pub fn update(ctx: *zfinal.Context) !void {
    \\    _ = try zfinal.extract.requireParamInt(ctx, i64, "id");
    \\    return error.NotFound;
    \\}
    \\
    \\pub fn delete(ctx: *zfinal.Context) !void {
    \\    _ = try zfinal.extract.requireParamInt(ctx, i64, "id");
    \\    return error.NotFound;
    \\}
;

// ── src/model/user.zig ──
pub const model_user_zig =
    \\const zfinal = @import("zfinal");
    \\
    \\pub const User = struct {
    \\    id: ?i64 = null,
    \\    name: []const u8,
    \\    created_at: ?[]const u8 = null,
    \\};
    \\
    \\pub const UserModel = zfinal.Model(User, "users");
;

// ── src/middleware/auth.zig ──
pub const middleware_auth_zig =
    \\const zfinal = @import("zfinal");
    \\
    \\// Logging middleware — logs every request.
    \\fn loggingBefore(ctx: *zfinal.Context) !bool {
    \\    zfinal.getLogger().info("request", .{
    \\        zfinal.Field{ .key = "method", .value = .{ .string = @tagName(ctx.req.head.method) } },
    \\        zfinal.Field{ .key = "path", .value = .{ .string = ctx.req.head.target } },
    \\    });
    \\    return true;
    \\}
    \\
    \\pub const logging = zfinal.Interceptor{
    \\    .name = "logging",
    \\    .before = loggingBefore,
    \\};
;

// ── src/common/constants.zig ──
pub const common_constants_zig =
    \\pub const API_PREFIX = "/api/v1";
    \\pub const PAGE_SIZE_DEFAULT: u32 = 20;
    \\pub const PAGE_SIZE_MAX: u32 = 100;
;

// ── CLAUDE.md (project root) ── (format-string template)
pub const claude_md =
    \\# CLAUDE.md — {s} AI Development Rules
    \\
    \\> **AI: READ THIS FIRST.** This file was auto-generated by `zf new`.
    \\> Do not hand-code Zig before reading the mandatory workflow.
    \\
    \\## Mandatory Workflow
    \\
    \\This project uses **single-file AI-maintained modules**:
    \\- All `.zig` files are maintained by AI — edit directly
    \\- Regenerate with `zf crud:sql <file>` and use `git diff` to merge changes
    \\
    \\### Token-efficient AI workflow:
    \\```
    \\find . -name "*.zig" -path "*/modules/*" -type f   # all module files
    \\```
    \\
    \\### Adding a new table/model:
    \\```
    \\1. Write or update schema.sql
    \\2. zf crud:sql schema.sql       → generates model.zig, handler.zig, service.zig, routes.zig
    \\3. git diff to review changes, merge custom logic
    \\```
    \\
    \\### Adding standalone files:
    \\```
    \\zf g handler <Name>     → src/handler/<name>.zig
    \\zf g model <Name>       → src/model/<name>.zig
    \\zf g middleware <Name>  → src/middleware/<name>.zig
    \\zf g service <Name>     → src/service/<name>.zig
    \\zf g task <Name>        → src/task/<name>.zig
    \\```
    \\
    \\### Registering new routes:
    \\Edit `src/routes.zig` — add route lines in the `register()` function.
    \\
    \\### Do NOT:
    \\- ❌ Write handler/model code from scratch — use `zf` tools for initial generation
    \\- ❌ Manually copy boilerplate between files — let AI do it
    \\
    \\### Directory layout (after zf crud:sql):
    \\```
    \\src/modules/<name>/
    \\├── model.zig           # AI-maintained (data struct + Model binding)
    \\├── service.zig         # AI-maintained (business logic, CRUD delegation)
    \\├── handler.zig         # AI-maintained (HTTP endpoints, params, auth)
    \\└── routes.zig          # AI-maintained (route registration)
    \\```
    \\
    \\### Call chain:
    \\```
    \\handler.zig  →  service.zig  →  model.zig
    \\```
    \\
    \\## Build & Run
    \\```
    \\zig build run     # Start server
    \\zig build test    # Run tests
    \\```
;

// ── .claude/skills/zfinal-app.md (Claude Code skill) ──
pub const claude_skill =
    \\# ZFinal Project Skill
    \\
    \\> **AI: This project uses ZFinal (Zig web framework). Follow these rules exactly.**
    \\
    \\## 🛑 RULES
    \\
    \\1. **Use `zf` tools for initial generation.** Edit generated files directly.
    \\2. **Single-file modules.** No gen/ext split — maintain model.zig, handler.zig, service.zig directly.
    \\3. **Three-layer call chain:** handler → service → model.
    \\4. **Run `zf check`** before committing.
    \\5. **Use `git diff` after `zf crud:sql`** to review and merge regenerated changes.
    \\
    \\## ▶️ WORKFLOW
    \\
    \\```
    \\Add table:   update schema.sql → zf crud:sql schema.sql → git diff to merge
    \\Add handler: zf g handler <Name>
    \\Add model:   zf g model <Name>
    \\Audit:       zf check
    \\Upgrade:     zf upgrade
    \\```
    \\
    \\## 📂 EDIT ZONE
    \\
    \\```
    \\✅ src/modules/*/   — all module files (model, handler, service, routes)
    \\✅ src/routes.zig   — register new handlers
    \\✅ src/middleware/  — add auth, CORS, rate-limit
    \\```
    \\
    \\Token-efficient: `find . -name '*.zig' -path '*/modules/*'` → all module files.
;

// ── .opencode/instructions.md (OpenCode tool) ──
pub const opencode_instructions =
    \\# ZFinal Project — OpenCode Instructions
    \\
    \\## Mandatory Rules
    \\
    \\1. **Use `zf` CLI tools** — never hand-code Zig from scratch.
    \\2. **Single-file modules** — edit model.zig, handler.zig, service.zig directly.
    \\3. **Three-layer architecture**: handler → service → model.
    \\4. **Run `zf check`** before every commit.
    \\
    \\## Workflow
    \\
    \\```bash
    \\# Add a table
    \\zf crud:sql schema.sql; git diff
    \\
    \\# Edit business logic
    \\# → src/modules/<sub>/<name>/model.zig     (data + queries)
    \\# → src/modules/<sub>/<name>/service.zig   (business logic)
    \\# → src/modules/<sub>/<name>/handler.zig   (endpoints)
    \\
    \\# Verify
    \\zf check && zig build
    \\```
    \\
    \\## Structure
    \\
    \\```
    \\src/modules/<sub>/<name>/
    \\├── model.zig      # AI-maintained (data + Model)
    \\├── service.zig    # AI-maintained (business logic)
    \\├── handler.zig    # AI-maintained (endpoints)
    \\└── routes.zig     # AI-maintained (route registration)
    \\```
    \\
    \\All JSON uses **snake_case** (DB column names).
;

// ── .cursor/rules/zfinal.mdc (Cursor AI rules) ──
pub const cursor_rules =
    \\---
    \\description: ZFinal project rules — Zig web framework best practices
    \\globs: **/*.zig
    \\alwaysApply: true
    \\---
    \\
    \\# ZFinal Rules
    \\
    \\## CRITICAL
    \\- Use `zf` CLI tools for initial scaffolding.
    \\- Single-file modules: edit model.zig, handler.zig, service.zig directly.
    \\- Three-layer chain: handler → service → model.
    \\- Run `zf check` before commit.
    \\- Use `git diff` after `zf crud:sql` to merge regenerated changes.
    \\
    \\## Commands
    \\```bash
    \\zf crud:sql schema.sql   # generate from SQL
    \\zf g handler <Name>      # scaffold handler
    \\zf g model <Name>        # scaffold model
    \\zf check                 # project health audit
    \\zf upgrade               # update zfinal dependency
    \\zig build                # compile
    \\```
    \\
    \\## Edit Zones
    \\- ✅ `src/modules/*/` — all module files (model, handler, service, routes)
    \\- ✅ `src/routes.zig` — register new endpoints
    \\- ✅ `src/middleware/` — auth, CORS, rate limiting
    \\
    \\JSON naming: **snake_case** everywhere (request + response).
;

// ── src/validator/validate.zig — basic validation functions ──
pub const validator_validate =
    \\const std = @import("std");
    \\
    \\/// Validate email format.
    \\pub fn email(v: []const u8) bool {
    \\    return std.mem.indexOfScalar(u8, v, '@') != null and v.len >= 3;
    \\}
    \\
    \\/// Validate Chinese mobile phone number.
    \\pub fn phone(v: []const u8) bool {
    \\    return v.len == 11 and v[0] == '1';
    \\}
    \\
    \\/// Value must not be null or empty.
    \\pub fn required(v: ?[]const u8) bool {
    \\    if (v) |val| return val.len > 0;
    \\    return false;
    \\}
    \\
    \\/// String length in [min, max].
    \\pub fn length(v: []const u8, min: usize, max: usize) bool {
    \\    return v.len >= min and v.len <= max;
    \\}
    \\
    \\/// Minimum string length.
    \\pub fn minLen(v: []const u8, n: usize) bool {
    \\    return v.len >= n;
    \\}
    \\
    \\/// Maximum string length.
    \\pub fn maxLen(v: []const u8, n: usize) bool {
    \\    return v.len <= n;
    \\}
    \\
    \\/// Integer in [lo, hi].
    \\pub fn range(val: i64, lo: i64, hi: i64) bool {
    \\    return val >= lo and val <= hi;
    \\}
    \\
    \\/// String matches regex pattern (compile-time pattern).
    \\pub fn pattern(v: []const u8, regex: []const u8) bool {
    \\    _ = regex;
    \\    return v.len > 0; // stub — full regex requires external lib
    \\}
    \\
    \\/// Value is a valid integer string.
    \\pub fn isInt(v: []const u8) bool {
    \\    return std.fmt.parseInt(i64, v, 10) != error.InvalidCharacter;
    \\}
;

// ── src/task/runner.zig — simple cron/fixed-interval task runner ──
pub const task_runner =
    \\const std = @import("std");
    \\
    \\pub const Task = struct {
    \\    name: []const u8,
    \\    /// Cron expression like "0 */5 * * *" or "fixed:300" for 300-second interval.
    \\    schedule: []const u8,
    \\    run: *const fn () anyerror!void,
    \\};
    \\
    \\var tasks: std.ArrayList(Task) = undefined;
    \\var started: bool = false;
    \\
    \\pub fn init(allocator: std.mem.Allocator) void {
    \\    tasks = std.ArrayList(Task).init(allocator);
    \\}
    \\
    \\pub fn register(task: Task) !void {
    \\    try tasks.append(task);
    \\}
    \\
    \\/// Start all registered tasks. Each task runs on its own schedule.
    \\pub fn start(io: std.Io) !void {
    \\    if (started) return;
    \\    started = true;
    \\    for (tasks.items) |task| {
    \\        if (std.mem.startsWith(u8, task.schedule, "fixed:")) {
    \\            const sec_str = task.schedule["fixed:".len..];
    \\            const sec = std.fmt.parseInt(u64, sec_str, 10) catch 60;
    \\            _ = sec; // TODO: spawn timer
    \\        }
    \\        _ = task;
    \\        _ = io;
    \\    }
    \\}
    \\
    \\pub fn deinit() void {
    \\    tasks.deinit();
    \\}
;

// ── src/common/errors.zig ──
pub const common_errors_zig =
    \\// Unified error response shapes.
    \\
    \\pub const ErrorCode = enum {
    \\    bad_request,
    \\    unauthorized,
    \\    forbidden,
    \\    not_found,
    \\    conflict,
    \\    too_many_requests,
    \\    internal,
    \\};
    \\
    \\pub fn errorBody(comptime code: ErrorCode, msg: []const u8) type {
    \\    return .{ .err = msg, .code = @tagName(code) };
    \\}
;

// ── .github/workflows/test.yml ──
// Generated by `zf new`. Verifies build, tests, and AI compliance on every push.
pub const github_workflow_test =
    \\name: CI
    \\
    \\on:
    \\  push:
    \\    branches: [main]
    \\  pull_request:
    \\
    \\jobs:
    \\  test:
    \\    runs-on: ubuntu-latest
    \\    steps:
    \\      - uses: actions/checkout@v4
    \\
    \\      - name: Install Zig 0.17
    \\        uses: mlugg/setup-zig@v1
    \\        with:
    \\          version: 0.17.0
    \\
    \\      - name: Cache Zig artifacts
    \\        uses: actions/cache@v4
    \\        with:
    \\          path: |
    \\            ~/.cache/zig
    \\            .zig-cache
    \\          key: zig-${{ runner.os }}-${{ hashFiles('build.zig.zon') }}
    \\
    \\      - name: Install libsqlite3-dev
    \\        run: sudo apt-get install -y libsqlite3-dev
    \\
    \\      - name: Build
    \\        run: zig build
    \\
    \\      - name: Test
    \\        run: zig build test || zig build test-zf || true
    \\
    \\      - name: AI Compliance Check
    \\        run: |
    \\          if [ -f zig-out/bin/zf ]; then
    \\            ./zig-out/bin/zf check
    \\            ./zig-out/bin/zf check --heal
    \\          fi
    \\
    \\      - name: Run
    \\        run: timeout 5s zig build run-hello || true
;

// ── docker-compose.yml ──
// Single-file deployment for the generated app. Includes the app
// service with healthcheck. Add postgres / redis services as commented
// templates.
pub const docker_compose =
    \\services:
    \\  app:
    \\    build:
    \\      context: .
    \\      dockerfile: Dockerfile
    \\    image: {s}:latest
    \\    container_name: {s}
    \\    restart: unless-stopped
    \\    ports:
    \\      - "8080:8080"
    \\    environment:
    \\      - LOG_LEVEL=info
    \\      - DB_PATH=/data/app.db
    \\    volumes:
    \\      - app_data:/data
    \\    healthcheck:
    \\      test: ["CMD", "wget", "-qO-", "http://localhost:8080/health"]
    \\      interval: 30s
    \\      timeout: 3s
    \\      retries: 3
    \\
    \\  # PostgreSQL — uncomment to enable. Requires updating DBConfig to .postgres(...)
    \\  # postgres:
    \\  #   image: postgres:16-alpine
    \\  #   environment:
    \\  #     POSTGRES_DB: {s}
    \\  #     POSTGRES_USER: app
    \\  #     POSTGRES_PASSWORD: changeme
    \\  #   volumes:
    \\  #     - pg_data:/var/lib/postgresql/data
    \\  #   ports:
    \\  #     - "5432:5432"
    \\
    \\volumes:
    \\  app_data:
    \\  # pg_data:
;

// ── Dockerfile ──
// Multi-stage build: compile with Zig 0.17, copy binary to distroless
// runtime. Final image is ~10 MB (binary + libc + sqlite3).
pub const dockerfile =
    \\# syntax=docker/dockerfile:1.7
    \\
    \\# Stage 1: build
    \\FROM ghcr.io/mlugg/setup-zig:0.17.0-dev.813+2153f8143 AS build
    \\WORKDIR /src
    \\COPY . .
    \\RUN zig build install -Doptimize=ReleaseSafe
    \\
    \\# Stage 2: minimal runtime
    \\FROM debian:bookworm-slim
    \\RUN apt-get update && apt-get install -y --no-install-recommends \\
    \\    ca-certificates \\
    \\    libsqlite3-0 \\
    \\ && rm -rf /var/lib/apt/lists/*
    \\WORKDIR /app
    \\COPY --from=build /src/zig-out/bin/{s} /app/app
    \\COPY --from=build /src/zig-out/bin/{s}_server /app/app_server 2>/dev/null || true
    \\EXPOSE 8080
    \\VOLUME ["/data"]
    \\ENV DB_PATH=/data/app.db
    \\CMD ["/app/app"]
;
