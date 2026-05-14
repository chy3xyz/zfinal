const std = @import("std");

// ── build.zig ── (format-string template — uses {{ }} escaping)
pub const build_zig =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {{
    \\    const target = b.standardTargetOptions(.{{}});
    \\    const optimize = b.standardOptimizeOption(.{{}});
    \\
    \\    // ZFinal dependency
    \\    const zfinal_dep = b.dependency("zfinal", .{{
    \\        .target = target,
    \\        .optimize = optimize,
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
    \\    .minimum_zig_version = "0.16.0",
    \\    .dependencies = .{{
    \\        .zfinal = .{{
    \\            .path = "../zfinal",
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
    \\pub fn main() !void {{
    \\    const allocator = std.heap.page_allocator;
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
    \\    zfinal.getLogger().info("starting", .{{
    \\        zfinal.Field{{ .key = "port", .value = .{{ .int = config.server.port }} }},
    \\    }});
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
    \\            .pool = zfinal.ConnectionPool.init(allocator, db_cfg, 8),
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
    \\    const id_str = ctx.getPathParam("id") orelse {
    \\        ctx.res_status = .bad_request;
    \\        return ctx.renderJson(.{ .err = "Missing ID" });
    \\    };
    \\    const id = std.fmt.parseInt(i64, id_str, 10) catch {
    \\        ctx.res_status = .bad_request;
    \\        return ctx.renderJson(.{ .err = "Invalid ID" });
    \\    };
    \\    _ = id; // TODO: lookup
    \\    ctx.res_status = .not_found;
    \\    try ctx.renderJson(.{ .err = "Not found" });
    \\}
    \\
    \\pub fn create(ctx: *zfinal.Context) !void {
    \\    const name = (try ctx.getPara("name")) orelse {
    \\        ctx.res_status = .bad_request;
    \\        return ctx.renderJson(.{ .err = "name required" });
    \\    };
    \\    _ = name; // TODO: persist
    \\    ctx.res_status = .created;
    \\    try ctx.renderJson(.{ .ok = true });
    \\}
    \\
    \\pub fn update(ctx: *zfinal.Context) !void {
    \\    ctx.res_status = .not_found;
    \\    try ctx.renderJson(.{ .err = "Not found" });
    \\}
    \\
    \\pub fn delete(ctx: *zfinal.Context) !void {
    \\    ctx.res_status = .not_found;
    \\    try ctx.renderJson(.{ .err = "Not found" });
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
    \\This project uses a **gen + ext/ two-directory pattern**:
    \\- `*.gen.zig` — generated by `zf crud:sql`, NEVER hand-edit
    \\- `ext/*.zig` — your business logic, safe to edit
    \\
    \\### Token-efficient AI workflow:
    \\```
    \\find . -path "*/ext/*.zig" -type f   # all AI-editable files in one read
    \\```
    \\
    \\### Adding a new table/model:
    \\```
    \\1. Write or update schema.sql
    \\2. zf crud:sql schema.sql       → generates .gen.zig files + ext/ stubs
    \\3. Edit ext/*.zig files to add custom queries
    \\```
    \\
    \\### Adding a handler/model/service/middleware/task:
    \\```
    \\zf g handler <Name>     → src/handler/ext/<name>.zig  (or src/handler/<name>.zig if no .gen)
    \\zf g model <Name>       → src/model/ext/<name>.zig
    \\zf g middleware <Name>  → src/middleware/<name>.zig
    \\zf g service <Name>     → src/service/<name>.zig
    \\zf g task <Name>        → src/task/<name>.zig
    \\```
    \\
    \\### Registering new routes:
    \\Edit `src/routes.zig` — add route lines in the `register()` function.
    \\
    \\### Do NOT:
    \\- ❌ Edit any `.gen.zig` file — it will be overwritten on regeneration
    \\- ❌ Write handler/model code from scratch — use `zf` tools
    \\- ❌ Put business logic outside `ext/` — keep it contained for AI efficiency
    \\
    \\### Directory layout (after zf crud:sql):
    \\```
    \\src/modules/<name>/
    \\├── model.gen.zig       # zf crud:sql — DO NOT EDIT
    \\├── service.gen.zig     # zf crud:sql — DO NOT EDIT (delegates CRUD to model)
    \\├── handler.gen.zig     # zf crud:sql — DO NOT EDIT (calls service)
    \\├── routes.zig          # zf crud:sql
    \\└── ext/                # ← AI WRITES HERE ONLY
    \\    ├── model.zig        # import "../model.gen.zig"  + custom queries
    \\    ├── service.zig      # import "../service.gen.zig" + business logic
    \\    └── handler.zig      # import "../handler.gen.zig" + custom endpoints
    \\```
    \\
    \\### Call chain:
    \\```
    \\handler.gen.zig  → service.gen.zig  → model.gen.zig
    \\     ↑                  ↑                  ↑
    \\ext/handler.zig   ext/service.zig    ext/model.zig
    \\```
    \\
    \\## Build & Run
    \\```
    \\zig build run     # Start server
    \\zig build test    # Run tests
    \\```
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
