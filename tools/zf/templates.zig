const std = @import("std");

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
    \\    const exe = b.addExecutable(.{{
    \\        .name = "{s}",
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\    }});
    \\
    \\    exe.root_module.addImport("zfinal", zfinal_mod);
    \\    exe.linkLibC();
    \\    // Default to SQLite
    \\    exe.linkSystemLibrary("sqlite3");
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

pub const build_zig_zon =
    \\.{{
    \\    .name = "{s}",
    \\    .version = "0.1.0",
    \\    .dependencies = .{{
    \\        .zfinal = .{{
    \\            .path = "../zfinal", // Assumes zfinal is a sibling directory
    \\        }},
    \\    }},
    \\    .paths = .{{
    \\        "build.zig",
    \\        "build.zig.zon",
    \\        "src",
    \\    }},
    \\}}
;

pub const main_zig =
    \\const std = @import("std");
    \\const zfinal = @import("zfinal");
    \\const Config = @import("config/config.zig");
    \\const Routes = @import("config/routes.zig");
    \\const DbInit = @import("config/db_init.zig");
    \\const Interceptors = @import("interceptor/interceptors.zig");
    \\
    \\pub fn main() !void {
    \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    \\    defer _ = gpa.deinit();
    \\    const allocator = gpa.allocator();
    \\
    \\    // Initialize Database
    \\    const db_config = Config.DBConfig.get();
    \\    var db = try zfinal.DB.init(allocator, db_config);
    \\    defer db.deinit();
    \\
    \\    // Initialize Tables
    \\    try DbInit.initDatabase(&db);
    \\
    \\    // Create App
    \\    var app = zfinal.ZFinal.init(allocator);
    \\    defer app.deinit();
    \\
    \\    app.setPort(Config.ServerConfig.port);
    \\
    \\    // Global Interceptors
    \\    try app.addGlobalInterceptor(Interceptors.LoggingInterceptor);
    \\
    \\    // Configure Routes
    \\    try Routes.configRoutes(&app);
    \\
    \\    // Start Server
    \\    std.debug.print("\nServer started at http://localhost:{d}\n", .{Config.ServerConfig.port});
    \\    try app.start();
    \\}
;

pub const config_config_zig =
    \\const zfinal = @import("zfinal");
    \\
    \\pub const ServerConfig = struct {
    \\    pub const port: u16 = 8080;
    \\};
    \\
    \\pub const DBConfig = struct {
    \\    pub fn get() zfinal.DBConfig {
    \\        return zfinal.DBConfig.sqlite("app.db");
    \\    }
    \\};
;

pub const config_routes_zig =
    \\const zfinal = @import("zfinal");
    \\const IndexController = @import("../controller/index_controller.zig").IndexController;
    \\
    \\pub fn configRoutes(app: *zfinal.ZFinal) !void {
    \\    try app.get("/", IndexController.index);
    \\}
;

pub const config_db_init_zig =
    \\const std = @import("std");
    \\const zfinal = @import("zfinal");
    \\
    \\pub fn initDatabase(db: *zfinal.DB) !void {
    \\    // Create tables here
    \\    try db.exec("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)");
    \\    std.debug.print("Database initialized.\n", .{});
    \\}
;

pub const controller_index_controller_zig =
    \\const zfinal = @import("zfinal");
    \\
    \\pub const IndexController = struct {
    \\    pub fn index(ctx: *zfinal.Context) !void {
    \\        try ctx.renderJson(.{
    \\            .message = "Welcome to zfinal!",
    \\            .version = "0.1.0",
    \\        });
    \\    }
    \\};
;

pub const interceptor_interceptors_zig =
    \\const std = @import("std");
    \\const zfinal = @import("zfinal");
    \\
    \\fn loggingBefore(ctx: *zfinal.Context) !bool {
    \\    const method = @tagName(ctx.req.head.method);
    \\    const path = ctx.req.head.target;
    \\    std.debug.print("[{s}] {s}\n", .{ method, path });
    \\    return true;
    \\}
    \\
    \\pub const LoggingInterceptor = zfinal.Interceptor{
    \\    .name = "logging",
    \\    .before = loggingBefore,
    \\};
;

pub const model_user_zig =
    \\const zfinal = @import("zfinal");
    \\
    \\pub const User = struct {
    \\    id: ?i64 = null,
    \\    name: []const u8,
    \\};
    \\
    \\pub const UserModel = zfinal.Model(User, "users");
;
