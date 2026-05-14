const std = @import("std");
const templates = @import("templates.zig");
const codegen = @import("codegen.zig");
const csql = @import("csql.zig");
const zf_cfg = @import("zf_cfg");

const Command = enum {
    new,
    generate,
    api,
    migrate,
    test_gen,
    docker,
    deploy,
    build_cmd,
    serve,
    test_run,
    version,
    help,
    crud,
    crud_sql,
    crud_dsn,
    life,
};

var io: std.Io = undefined;

pub fn main(init: std.process.Init) !void {
    io = init.io;
    const allocator = init.gpa;

    var args_iter = init.minimal.args.iterate();
    defer args_iter.deinit();

    const argv0 = args_iter.next() orelse {
        std.debug.print("Usage: zf <command>\n", .{});
        return;
    };

    // Collect all args for index-based access
    var args_list = std.ArrayList([]const u8).empty;
    defer args_list.deinit(allocator);
    try args_list.append(allocator, argv0);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    const command_str = if (args.len > 1) args[1] else {
        printHelp(argv0);
        return;
    };

    const command = parseCommand(command_str) orelse {
        std.debug.print("Unknown command: {s}\n\n", .{command_str});
        printHelp(argv0);
        return;
    };

    switch (command) {
        .new => {
            if (args.len < 3) {
                std.debug.print("Usage: {s} new <project_name>\n", .{argv0});
                return;
            }
            try createProject(allocator, args[2]);
        },
        .generate => {
            if (args.len < 4) {
                std.debug.print("Usage: {s} generate <type> <name>\n", .{args[0]});
                std.debug.print("Types: controller, model, interceptor, plugin\n", .{});
                return;
            }
            try generateCode(allocator, args[2], args[3], false);
        },
        .api => {
            if (args.len < 3) {
                std.debug.print("Usage: {s} api <name>\n", .{args[0]});
                std.debug.print("Generate API handler (JSON output)\n", .{});
                return;
            }
            try generateCode(allocator, "handler", args[2], true);
        },
        .migrate => {
            if (args.len < 3) {
                std.debug.print("Usage: {s} migrate <action> [name]\n", .{args[0]});
                std.debug.print("Actions: new <name>, run\n", .{});
                return;
            }
            try handleMigrate(allocator, args[2], if (args.len > 3) args[3] else "");
        },
        .test_gen => {
            if (args.len < 3) {
                std.debug.print("Usage: {s} test:gen <name>\n", .{args[0]});
                return;
            }
            try generateTest(allocator, args[2]);
        },
        .docker => try generateDocker(allocator),
        .deploy => try handleDeploy(allocator),
        .build_cmd => {
            std.debug.print("Building release binary...\n", .{});
            std.debug.print("Run: zig build -Doptimize=ReleaseSafe\n", .{});
        },
        .serve => {
            std.debug.print("Starting development server...\n", .{});
            std.debug.print("Run: zig build run\n", .{});
        },
        .test_run => {
            std.debug.print("Running tests...\n", .{});
            std.debug.print("Run: zig build test\n", .{});
        },
        .version => {
            std.debug.print("ZFinal CLI (zf) version 0.3.0\n", .{});
            std.debug.print("Zig Web Framework inspired by JFinal\n", .{});
        },
        .help => printHelp(args[0]),
        .crud => {
            if (args.len < 4) {
                std.debug.print("Usage: {s} crud <db_path> <table_name>\n", .{args[0]});
                std.debug.print("Example: {s} crud myapp.db users\n", .{args[0]});
                return;
            }
            try handleCrud(allocator, args[2], args[3]);
        },
        .crud_sql => {
            if (args.len < 3) {
                std.debug.print("Usage: {s} crud:sql <sql_file>\n", .{args[0]});
                return;
            }
            try handleCrudFromSql(allocator, args[2]);
        },
        .crud_dsn => {
            if (args.len < 3) {
                std.debug.print("Usage: {s} crud:dsn <dsn_url>\n", .{args[0]});
                std.debug.print("  postgres://user:pass@host:port/dbname\n", .{});
                std.debug.print("  mysql://user:pass@host:port/dbname\n", .{});
                return;
            }
            try handleCrudFromDsn(allocator, args[2]);
        },
        .life => {
            const sub = if (args.len > 2) args[2] else "status";
            try handleLife(allocator, sub, if (args.len > 3) args[3] else "");
        },
    }
}

fn parseCommand(cmd: []const u8) ?Command {
    if (std.mem.eql(u8, cmd, "new")) return .new;
    if (std.mem.eql(u8, cmd, "generate") or std.mem.eql(u8, cmd, "g")) return .generate;
    if (std.mem.eql(u8, cmd, "api")) return .api;
    if (std.mem.eql(u8, cmd, "migrate")) return .migrate;
    if (std.mem.eql(u8, cmd, "test:gen")) return .test_gen;
    if (std.mem.eql(u8, cmd, "docker")) return .docker;
    if (std.mem.eql(u8, cmd, "deploy")) return .deploy;
    if (std.mem.eql(u8, cmd, "build") or std.mem.eql(u8, cmd, "b")) return .build_cmd;
    if (std.mem.eql(u8, cmd, "serve") or std.mem.eql(u8, cmd, "s")) return .serve;
    if (std.mem.eql(u8, cmd, "test") or std.mem.eql(u8, cmd, "t")) return .test_run;
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "v")) return .version;
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h")) return .help;
    if (std.mem.eql(u8, cmd, "crud")) return .crud;
    if (std.mem.eql(u8, cmd, "crud:sql")) return .crud_sql;
    if (std.mem.eql(u8, cmd, "crud:dsn")) return .crud_dsn;
    if (std.mem.eql(u8, cmd, "life")) return .life;
    return null;
}

fn printHelp(exe_name: []const u8) void {
    std.debug.print("\n", .{});
    std.debug.print("ZFinal CLI (zf) - Zig Web Framework Tool\n", .{});
    std.debug.print("=========================================\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Usage: {s} <command> [options]\n", .{exe_name});
    std.debug.print("\n", .{});
    std.debug.print("Commands:\n", .{});
    std.debug.print("  new <name>              Create a new ZFinal project (HTMX template)\n", .{});
    std.debug.print("  generate, g <type> <name>  Generate code (handler, model, middleware, service, task)\n", .{});
    std.debug.print("  api <name>              Generate API handler (JSON output)\n", .{});
    std.debug.print("  migrate <action> [name] Manage database migrations\n", .{});
    std.debug.print("  test:gen <name>         Generate test file\n", .{});
    std.debug.print("  crud <db> <table>       Generate full CRUD from SQLite DB schema\n", .{});
    std.debug.print("  crud:sql <file|--dsn>   Generate from .sql file or DSN URL (postgres:// mysql://)\n", .{});
    std.debug.print("  docker                  Generate Dockerfile\n", .{});
    std.debug.print("  deploy                  Deploy application\n", .{});
    std.debug.print("  build, b                Build release binary\n", .{});
    std.debug.print("  serve, s                Start development server (zig build run)\n", .{});
    std.debug.print("  test, t                 Run tests (zig build test)\n", .{});
    std.debug.print("  version, v              Show version information\n", .{});
    std.debug.print("  help, h                 Show this help message\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Examples:\n", .{});
    std.debug.print("  {s} new myapp           Create a new project named 'myapp'\n", .{exe_name});
    std.debug.print("  {s} g handler User      Generate User handler\n", .{exe_name});
    std.debug.print("  {s} g model Product     Generate Product model\n", .{exe_name});
    std.debug.print("  {s} g middleware Auth   Generate Auth middleware\n", .{exe_name});
    std.debug.print("  {s} g task CleanupJob   Generate scheduled task\n", .{exe_name});
    std.debug.print("  {s} migrate new init    Create initial migration\n", .{exe_name});
    std.debug.print("  {s} docker              Generate Dockerfile\n", .{exe_name});
    std.debug.print("  {s} build               Build optimized binary\n", .{exe_name});
    std.debug.print("  {s} serve               Start the development server\n", .{exe_name});
    std.debug.print("\n", .{});
}

fn createProject(allocator: std.mem.Allocator, project_name: []const u8) !void {
    const cwd = std.Io.Dir.cwd();

    // Create project directory
    try cwd.createDirPath(io, project_name);
    var project_dir = try cwd.openDir(io, project_name, .{});
    defer project_dir.close(io);

    std.debug.print("\nCreating project: {s}\n", .{project_name});

    // Root: build.zig + build.zig.zon + CLAUDE.md
    const build_zig_content = try std.fmt.allocPrint(allocator, templates.build_zig, .{project_name});
    defer allocator.free(build_zig_content);
    try writeFile(project_dir, "build.zig", build_zig_content);

    const build_zon_content = try std.fmt.allocPrint(allocator, templates.build_zig_zon, .{project_name});
    defer allocator.free(build_zon_content);
    try writeFile(project_dir, "build.zig.zon", build_zon_content);

    const claude_md_content = try std.fmt.allocPrint(allocator, templates.claude_md, .{project_name});
    defer allocator.free(claude_md_content);
    try writeFile(project_dir, "CLAUDE.md", claude_md_content);

    // src/
    try project_dir.createDirPath(io, "src");
    var src_dir = try project_dir.openDir(io, "src", .{});
    defer src_dir.close(io);

    // src/main.zig — entry point
    const main_content = try std.fmt.allocPrint(allocator, templates.main_zig, .{project_name});
    defer allocator.free(main_content);
    try writeFile(src_dir, "main.zig", main_content);

    // src/App.zig — application assembly
    try writeFile(src_dir, "App.zig", templates.app_zig);

    // src/config.zig — single config file
    try writeFile(src_dir, "config.zig", templates.config_zig);

    // src/routes.zig — centralised route table
    try writeFile(src_dir, "routes.zig", templates.routes_zig);

    // src/handler/
    try src_dir.createDirPath(io, "handler");
    var handler_dir = try src_dir.openDir(io, "handler", .{});
    defer handler_dir.close(io);
    const index_content = try std.fmt.allocPrint(allocator, templates.handler_index_zig, .{project_name});
    defer allocator.free(index_content);
    try writeFile(handler_dir, "index.zig", index_content);
    try writeFile(handler_dir, "user.zig", templates.handler_user_zig);

    // src/service/ — business logic layer
    try src_dir.createDirPath(io, "service");

    // src/model/
    try src_dir.createDirPath(io, "model");
    var model_dir = try src_dir.openDir(io, "model", .{});
    defer model_dir.close(io);
    try writeFile(model_dir, "user.zig", templates.model_user_zig);

    // src/middleware/
    try src_dir.createDirPath(io, "middleware");
    var middleware_dir = try src_dir.openDir(io, "middleware", .{});
    defer middleware_dir.close(io);
    try writeFile(middleware_dir, "auth.zig", templates.middleware_auth_zig);

    // src/validator/
    try src_dir.createDirPath(io, "validator");

    // src/task/
    try src_dir.createDirPath(io, "task");

    // src/common/
    try src_dir.createDirPath(io, "common");
    var common_dir = try src_dir.openDir(io, "common", .{});
    defer common_dir.close(io);
    try writeFile(common_dir, "constants.zig", templates.common_constants_zig);
    try writeFile(common_dir, "errors.zig", templates.common_errors_zig);

    // test/
    try project_dir.createDirPath(io, "test");
    try project_dir.createDirPath(io, "test/handler");

    std.debug.print("\n✅ Project '{s}' created!\n", .{project_name});
    std.debug.print("\n", .{});
    std.debug.print("  ├── CLAUDE.md          AI guard rails (read first)\n", .{});
    std.debug.print("  ├── build.zig\n", .{});
    std.debug.print("  ├── build.zig.zon\n", .{});
    std.debug.print("  ├── main.zig          Entry point\n", .{});
    std.debug.print("  ├── App.zig           Application assembly\n", .{});
    std.debug.print("  ├── config.zig        Configuration\n", .{});
    std.debug.print("  ├── routes.zig        Centralised route table\n", .{});
    std.debug.print("  ├── handler/          HTTP handlers\n", .{});
    std.debug.print("  ├── service/          Business logic\n", .{});
    std.debug.print("  ├── model/            Database models\n", .{});
    std.debug.print("  ├── middleware/        Auth / CORS / rate-limit\n", .{});
    std.debug.print("  ├── validator/         Input validation\n", .{});
    std.debug.print("  ├── task/              Scheduled tasks\n", .{});
    std.debug.print("  └── common/            Constants / errors / types\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  cd {s}\n", .{project_name});
    std.debug.print("  zig build run\n", .{});
    std.debug.print("\n", .{});
}

fn generateCode(allocator: std.mem.Allocator, gen_type: []const u8, name: []const u8, is_api: bool) !void {
    if (name.len == 0) {
        std.debug.print("Error: Name is required\n", .{});
        return;
    }

    if (std.mem.eql(u8, gen_type, "handler")) {
        try generateHandler(allocator, name, is_api);
    } else if (std.mem.eql(u8, gen_type, "model")) {
        try generateModel(allocator, name);
    } else if (std.mem.eql(u8, gen_type, "middleware")) {
        try generateMiddleware(allocator, name);
    } else if (std.mem.eql(u8, gen_type, "service")) {
        try generateService(allocator, name);
    } else if (std.mem.eql(u8, gen_type, "task")) {
        try generateTask(allocator, name);
    } else if (std.mem.eql(u8, gen_type, "controller")) {
        // Backward compat: map controller → handler
        try generateHandler(allocator, name, is_api);
    } else {
        std.debug.print("Unknown type: {s}\n", .{gen_type});
        std.debug.print("Available: handler, model, middleware, service, task\n", .{});
    }
}

fn generateHandler(allocator: std.mem.Allocator, name: []const u8, is_api: bool) !void {
    std.Io.Dir.cwd().access(io, "src/handler", .{}) catch {
        std.debug.print("Error: src/handler directory not found. Run 'zf new' first.\n", .{});
        return;
    };

    const name_lower = try std.ascii.allocLowerString(allocator, name);
    defer allocator.free(name_lower);

    // Check if .gen.zig exists — if so, write ext stub to ext/ subdirectory
    const gen_path = try std.fmt.allocPrint(allocator, "src/handler/{s}.gen.zig", .{name_lower});
    defer allocator.free(gen_path);
    const has_gen = std.Io.Dir.cwd().access(io, gen_path, .{}) != error.FileNotFound;

    const base_dir = if (has_gen) "src/handler/ext" else "src/handler";
    const filename = try std.fmt.allocPrint(allocator, "{s}/{s}.zig", .{ base_dir, name_lower });
    defer allocator.free(filename);

    if (has_gen) try ensureDir(allocator, "src/handler/ext");

    // Skip if ext file already exists (protect user code)
    if (std.Io.Dir.cwd().access(io, filename, .{})) |_| {
        std.debug.print("⚠ Skip (exists): {s}\n", .{filename});
        return;
    } else |_| {}

    const content = if (has_gen)
        try std.fmt.allocPrint(allocator,
            \\const std = @import("std");
            \\const zfinal = @import("zfinal");
            \\const gen = @import("../{s}.gen.zig");
            \\
            \\pub const list = gen.list;
            \\pub const show = gen.show;
            \\pub const create = gen.create;
            \\pub const update = gen.update;
            \\pub const delete = gen.delete;
            \\
            \\// ── Custom handlers — add your endpoint logic here ──
            \\
        , .{name_lower})
    else
        try std.fmt.allocPrint(allocator,
            \\const std = @import("std");
            \\const zfinal = @import("zfinal");
            \\
            \\pub fn list(ctx: *zfinal.Context) !void {{
            \\    try ctx.renderJson(.{{ .data = &.{{}} }});
            \\}}
            \\
            \\pub fn show(ctx: *zfinal.Context) !void {{
            \\    const id_str = ctx.getPathParam("id") orelse {{
            \\        ctx.res_status = .bad_request;
            \\        return ctx.renderJson(.{{ .err = "Missing ID" }});
            \\    }};
            \\    const id = std.fmt.parseInt(i64, id_str, 10) catch {{
            \\        ctx.res_status = .bad_request;
            \\        return ctx.renderJson(.{{ .err = "Invalid ID" }});
            \\    }};
            \\    _ = id;
            \\    ctx.res_status = .not_found;
            \\    try ctx.renderJson(.{{ .err = "Not found" }});
            \\}}
            \\
            \\pub fn create(ctx: *zfinal.Context) !void {{
            \\    ctx.res_status = .created;
            \\    try ctx.renderJson(.{{ .ok = true }});
            \\}}
            \\
            \\pub fn update(ctx: *zfinal.Context) !void {{
            \\    ctx.res_status = .not_found;
            \\    try ctx.renderJson(.{{ .err = "Not found" }});
            \\}}
            \\
            \\pub fn delete(ctx: *zfinal.Context) !void {{
            \\    ctx.res_status = .not_found;
            \\    try ctx.renderJson(.{{ .err = "Not found" }});
            \\}}
        , .{});
    defer allocator.free(content);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = filename, .data = content });
    const mode_str = if (is_api) "API" else "";
    const tag = if (has_gen) "ext" else "handler";
    std.debug.print("✅ Generated {s} {s}: {s}\n", .{ mode_str, tag, filename });

    // Also generate a test stub
    const test_filename = try std.fmt.allocPrint(allocator, "test/handler/{s}_test.zig", .{name_lower});
    defer allocator.free(test_filename);
    const test_content = try std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\const zfinal = @import("zfinal");
        \\
        \\test "{s} handler: list returns 200" {{
        \\    _ = zfinal;
        \\    // TODO: init test App, call handler, assert
        \\}}
    , .{name_lower});
    defer allocator.free(test_content);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = test_filename, .data = test_content }) catch {};
}

fn generateModel(allocator: std.mem.Allocator, name: []const u8) !void {
    std.Io.Dir.cwd().access(io, "src/model", .{}) catch {
        std.debug.print("Error: src/model directory not found. Run 'zf new' first.\n", .{});
        return;
    };

    const name_lower = try std.ascii.allocLowerString(allocator, name);
    defer allocator.free(name_lower);

    // Check if .gen.zig exists — if so, generate ext stub in ext/ subdirectory
    const gen_path = try std.fmt.allocPrint(allocator, "src/model/{s}.gen.zig", .{name_lower});
    defer allocator.free(gen_path);
    const has_gen = std.Io.Dir.cwd().access(io, gen_path, .{}) != error.FileNotFound;

    const base_dir = if (has_gen) "src/model/ext" else "src/model";
    const filename = try std.fmt.allocPrint(allocator, "{s}/{s}.zig", .{ base_dir, name_lower });
    defer allocator.free(filename);

    if (has_gen) try ensureDir(allocator, "src/model/ext");

    // Skip if ext file already exists (protect user code)
    if (std.Io.Dir.cwd().access(io, filename, .{})) |_| {
        std.debug.print("⚠ Skip (exists): {s}\n", .{filename});
        return;
    } else |_| {}

    const model_name = try capitalizeOwned(allocator, name);
    defer allocator.free(model_name);

    var content_buf: []const u8 = undefined;
    if (has_gen) {
        content_buf = try std.fmt.allocPrint(allocator,
            \\const std = @import("std");
            \\const zfinal = @import("zfinal");
            \\const gen = @import("../{s}.gen.zig");
            \\
            \\pub const {s} = gen.{s};
            \\pub const {s}Model = gen.{s}Model;
            \\pub const validate = gen.validate;
            \\
            \\// ── Custom queries ──
            \\
        , .{ name_lower, model_name, model_name, model_name, model_name });
    } else {
        const table_name = try std.fmt.allocPrint(allocator, "{s}s", .{name_lower});
        defer allocator.free(table_name);
        content_buf = try std.fmt.allocPrint(allocator,
            \\const zfinal = @import("zfinal");
            \\
            \\pub const {s} = struct {{
            \\    id: ?i64 = null,
            \\    name: []const u8,
            \\    created_at: ?[]const u8 = null,
            \\}};
            \\
            \\pub const {s}Model = zfinal.Model({s}, "{s}");
            \\
        , .{ model_name, model_name, model_name, table_name });
    }
    const content = content_buf;
    defer allocator.free(content);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = filename, .data = content });
    const tag = if (has_gen) "ext" else "model";
    std.debug.print("✅ Generated {s}: {s}\n", .{ tag, filename });
}

fn generateMiddleware(allocator: std.mem.Allocator, name: []const u8) !void {
    std.Io.Dir.cwd().access(io, "src/middleware", .{}) catch {
        std.debug.print("Error: src/middleware directory not found. Run 'zf new' first.\n", .{});
        return;
    };

    const name_lower = try std.ascii.allocLowerString(allocator, name);
    defer allocator.free(name_lower);

    const filename = try std.fmt.allocPrint(allocator, "src/middleware/{s}.zig", .{name_lower});
    defer allocator.free(filename);

    const mw_name = try capitalizeOwned(allocator, name);
    defer allocator.free(mw_name);

    const content = try std.fmt.allocPrint(allocator,
        \\const zfinal = @import("zfinal");
        \\
        \\fn {s}Before(ctx: *zfinal.Context) !bool {{
        \\    // Add middleware logic here
        \\    _ = ctx;
        \\    return true;
        \\}}
        \\
        \\pub const {s}Middleware = zfinal.Interceptor{{
        \\    .name = "{s}",
        \\    .before = {s}Before,
        \\}};
    , .{ name_lower, mw_name, name_lower, name_lower });
    defer allocator.free(content);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = filename, .data = content });
    std.debug.print("✅ Generated: {s}\n", .{filename});
}

fn generateService(allocator: std.mem.Allocator, name: []const u8) !void {
    std.Io.Dir.cwd().access(io, "src/service", .{}) catch {
        std.debug.print("Error: src/service directory not found. Run 'zf new' first.\n", .{});
        return;
    };

    const name_lower = try std.ascii.allocLowerString(allocator, name);
    defer allocator.free(name_lower);

    const filename = try std.fmt.allocPrint(allocator, "src/service/{s}.zig", .{name_lower});
    defer allocator.free(filename);

    const svc_name = try capitalizeOwned(allocator, name);
    defer allocator.free(svc_name);

    const content = try std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\const zfinal = @import("zfinal");
        \\
        \\pub fn doWork(ctx: *zfinal.Context) !void {{
        \\    _ = ctx;
        \\    // TODO: business logic here
        \\}}
    , .{});
    defer allocator.free(content);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = filename, .data = content });
    std.debug.print("✅ Generated: {s}\n", .{filename});
}

fn generateTask(allocator: std.mem.Allocator, name: []const u8) !void {
    std.Io.Dir.cwd().access(io, "src/task", .{}) catch {
        std.debug.print("Error: src/task directory not found. Run 'zf new' first.\n", .{});
        return;
    };

    const name_lower = try std.ascii.allocLowerString(allocator, name);
    defer allocator.free(name_lower);

    const filename = try std.fmt.allocPrint(allocator, "src/task/{s}.zig", .{name_lower});
    defer allocator.free(filename);

    const task_name = try capitalizeOwned(allocator, name);
    defer allocator.free(task_name);

    const content = try std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\const zfinal = @import("zfinal");
        \\
        \\pub fn run() !void {{
        \\    zfinal.getLogger().info("{s}: running", .{{}});
        \\    // TODO: task logic here
        \\}}
    , .{name_lower});
    defer allocator.free(content);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = filename, .data = content });
    std.debug.print("✅ Generated: {s}\n", .{filename});
}

fn writeFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    const file = try dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

fn capitalizeOwned(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
    if (str.len == 0) return try allocator.dupe(u8, str);
    var result = try allocator.alloc(u8, str.len);
    result[0] = std.ascii.toUpper(str[0]);
    @memcpy(result[1..], str[1..]);
    return result;
}

fn handleMigrate(allocator: std.mem.Allocator, action: []const u8, name: []const u8) !void {
    if (std.mem.eql(u8, action, "new")) {
        if (name.len == 0) {
            std.debug.print("Error: Migration name is required\n", .{});
            return;
        }

        const migrations_dir = "migrations";
        std.Io.Dir.cwd().createDirPath(io, migrations_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const timestamp = std.Io.Timestamp.now(io, .real).toSeconds();
        const filename = try std.fmt.allocPrint(allocator, "{s}/{d}_{s}.sql", .{ migrations_dir, timestamp, name });
        defer allocator.free(filename);

        const content =
            \\-- Migration: {s}
            \\-- Created at: {d}
            \\
            \\-- Up
            \\CREATE TABLE {s} (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\);
            \\
            \\-- Down
            \\DROP TABLE {s};
            \\
        ;
        // Note: Simple format string, not using the name in SQL to avoid issues, just a template
        const file_content = try std.fmt.allocPrint(allocator, content, .{ name, timestamp, name, name });
        defer allocator.free(file_content);

        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = filename, .data = file_content });
        std.debug.print("✅ Created migration: {s}\n", .{filename});
    } else if (std.mem.eql(u8, action, "run")) {
        std.debug.print("Running migrations...\n", .{});
        // TODO: Implement actual migration runner
        std.debug.print("⚠️  Migration runner not yet implemented in CLI.\n", .{});
        std.debug.print("Please use 'zig build migrate' if available or run SQL files manually.\n", .{});
    } else {
        std.debug.print("Unknown migration action: {s}\n", .{action});
        std.debug.print("Available actions: new, run\n", .{});
    }
}

fn generateTest(allocator: std.mem.Allocator, name: []const u8) !void {
    const test_dir = "test";
    std.Io.Dir.cwd().createDirPath(io, test_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const name_lower = try std.ascii.allocLowerString(allocator, name);
    defer allocator.free(name_lower);

    const filename = try std.fmt.allocPrint(allocator, "{s}/{s}_test.zig", .{ test_dir, name_lower });
    defer allocator.free(filename);

    const content = try std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\const zfinal = @import("zfinal");
        \\const testing = std.testing;
        \\
        \\test "{s} basic functionality" {{
        \\    const allocator = std.testing.allocator;
        \\    // Test logic here
        \\    try testing.expect(true);
        \\}}
        \\
    , .{name});
    defer allocator.free(content);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = filename, .data = content });
    std.debug.print("✅ Generated test file: {s}\n", .{filename});
}

fn generateDocker(_: std.mem.Allocator) !void {
    const dockerfile_content =
        \\FROM alpine:latest
        \\
        \\WORKDIR /app
        \\
        \\# Install runtime dependencies
        \\RUN apk add --no-cache libgcc
        \\
        \\# Copy binary
        \\COPY zig-out/bin/* /app/server
        \\
        \\# Copy templates and static files if they exist
        \\COPY src/templates /app/src/templates
        \\COPY static /app/static
        \\
        \\EXPOSE 8080
        \\
        \\CMD ["/app/server"]
        \\
    ;

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "Dockerfile", .data = dockerfile_content });
    std.debug.print("✅ Generated Dockerfile\n", .{});

    const dockerignore_content =
        \\zig-cache/
        \\zig-out/
        \\.git/
        \\.github/
        \\*.md
        \\
    ;

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ".dockerignore", .data = dockerignore_content });
    std.debug.print("✅ Generated .dockerignore\n", .{});
}

fn handleDeploy(allocator: std.mem.Allocator) !void {
    const deploy_script = "deploy.sh";

    // Check if deploy script exists
    std.Io.Dir.cwd().access(io, deploy_script, .{}) catch {
        // Create default deploy script if not exists
        const content =
            \\#!/bin/bash
            \\echo "Deploying application..."
            \\
            \\# Build release binary
            \\zig build -Doptimize=ReleaseSafe
            \\
            \\# Docker build (optional)
            \\# docker build -t myapp .
            \\
            \\# Add your deployment commands here
            \\# e.g., scp, rsync, or docker push
            \\
            \\echo "Deployment script finished."
            \\
        ;
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = deploy_script, .data = content });

        // Make executable
        _ = try std.process.run(allocator, io, .{
            .argv = &[_][]const u8{ "chmod", "+x", deploy_script },
        });

        std.debug.print("✅ Created default deployment script: {s}\n", .{deploy_script});
        std.debug.print("Please edit it to match your deployment needs.\n", .{});
        return;
    };

    // Run existing deploy script
    std.debug.print("Running deployment script...\n", .{});
    const result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{"./deploy.sh"},
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    std.debug.print("{s}\n", .{result.stdout});
    if (result.stderr.len > 0) {
        std.debug.print("Error: {s}\n", .{result.stderr});
    }
}

fn generatePlugin(allocator: std.mem.Allocator, name: []const u8) !void {
    // Check if src/plugin directory exists
    const plugin_dir = "src/plugin";
    std.Io.Dir.cwd().createDirPath(io, plugin_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const name_lower = try std.ascii.allocLowerString(allocator, name);
    defer allocator.free(name_lower);

    // Determine which plugin template to use
    if (std.mem.eql(u8, name_lower, "mqtt")) {
        try copyPluginFile(allocator, "mqtt.zig");
    } else if (std.mem.eql(u8, name_lower, "agent") or std.mem.eql(u8, name_lower, "mcp")) {
        try copyPluginFile(allocator, "agent.zig");
    } else if (std.mem.eql(u8, name_lower, "did")) {
        try copyPluginFile(allocator, "did.zig");
    } else if (std.mem.eql(u8, name_lower, "p2p")) {
        try copyPluginFile(allocator, "p2p.zig");
    } else {
        // Generic plugin template
        const filename = try std.fmt.allocPrint(allocator, "src/plugin/{s}.zig", .{name_lower});
        defer allocator.free(filename);

        const plugin_name = try capitalizeOwned(allocator, name);
        defer allocator.free(plugin_name);

        const content = try std.fmt.allocPrint(allocator,
            \\const std = @import("std");
            \\const zfinal = @import("zfinal");
            \\
            \\pub const {s}Plugin = struct {{
            \\    allocator: std.mem.Allocator,
            \\
            \\    pub fn init(allocator: std.mem.Allocator) {s}Plugin {{
            \\        return {s}Plugin{{
            \\            .allocator = allocator,
            \\        }};
            \\    }}
            \\
            \\    pub fn deinit(self: *{s}Plugin) void {{
            \\        _ = self;
            \\    }}
            \\
            \\    pub fn plugin(self: *{s}Plugin) zfinal.Plugin {{
            \\        return zfinal.Plugin{{
            \\            .name = "{s}",
            \\            .vtable = &.{{
            \\                .start = start,
            \\                .stop = stop,
            \\            }},
            \\            .context = self,
            \\        }};
            \\    }}
            \\
            \\    fn start(ctx: *anyopaque) !void {{
            \\        std.debug.print("Starting {s} Plugin...\n", .{{}});
            \\    }}
            \\
            \\    fn stop(ctx: *anyopaque) !void {{
            \\        std.debug.print("Stopping {s} Plugin...\n", .{{}});
            \\    }}
            \\}};
            \\
        , .{ plugin_name, plugin_name, plugin_name, plugin_name, plugin_name, plugin_name, plugin_name, plugin_name });
        defer allocator.free(content);

        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = filename, .data = content });
        std.debug.print("✅ Generated generic plugin: {s}\n", .{filename});
    }
}

fn handleLife(allocator: std.mem.Allocator, sub: []const u8, _: []const u8) !void {
    if (std.mem.eql(u8, sub, "status")) {
        // Check if .life directory exists
        std.Io.Dir.cwd().access(io, ".life", .{}) catch {
            std.debug.print("No .life directory found. Run 'zf life init' first.\n", .{});
            return;
        };
        std.debug.print("Project Life Status\n", .{});
        std.debug.print("==================\n", .{});
        std.debug.print("Directory: .life/ exists\n", .{});
        std.debug.print("Fingerprints: ", .{});
        var fp_dir = std.Io.Dir.cwd().openDir(io, ".life/fingerprints", .{ .iterate = true }) catch {
            std.debug.print("none\n", .{});
            return;
        };
        defer fp_dir.close(io);
        var it = fp_dir.iterate();
        var count: usize = 0;
        while (try it.next(io)) |entry| {
            if (entry.name[0] != '.') count += 1;
        }
        std.debug.print("{d} milestones\n", .{count});
        std.debug.print("Decisions: .life/decisions/\n", .{});
        std.debug.print("Evolution: .life/evolution.md\n", .{});
        std.debug.print("DNA: .life/dna.json\n", .{});
    } else if (std.mem.eql(u8, sub, "init")) {
        try ensureDir(allocator, ".life");
        try ensureDir(allocator, ".life/fingerprints");
        try ensureDir(allocator, ".life/decisions");
        try ensureDir(allocator, ".life/memory");
        std.debug.print("✅ Initialized .life/ directory\n", .{});
    } else if (std.mem.eql(u8, sub, "fingerprint")) {
        std.debug.print("Project Fingerprint\n", .{});
        std.debug.print("==================\n", .{});
        const ts = std.Io.Timestamp.now(io, .real).toSeconds();
        std.debug.print("Timestamp: {d}\n", .{ts});
        std.debug.print("Fingerprint: zf-{d}\n", .{ts});
    } else {
        std.debug.print("Unknown life command: {s}\n", .{sub});
        std.debug.print("Available: init, status, fingerprint\n", .{});
    }
}

fn handleCrud(allocator: std.mem.Allocator, db_path: []const u8, table_name: []const u8) !void {
    const c = @cImport({ @cInclude("sqlite3.h"); });

    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open(db_path.ptr, &db);
    if (rc != c.SQLITE_OK) {
        std.debug.print("Failed to open database: {s}\n", .{db_path});
        return;
    }
    defer _ = c.sqlite3_close(db);

    // Read column info via PRAGMA
    var stmt: ?*c.sqlite3_stmt = null;
    var pragma_buf: [256]u8 = undefined;
    const pragma_sql = try std.fmt.bufPrintZ(&pragma_buf, "PRAGMA table_info({s})", .{table_name});
    _ = c.sqlite3_prepare_v2(db, pragma_sql.ptr, @intCast(pragma_sql.len + 1), &stmt, null);
    if (stmt == null) {
        std.debug.print("Table '{s}' not found in database.\n", .{table_name});
        return;
    }
    defer _ = c.sqlite3_finalize(stmt);

    var table = codegen.Table{
        .name = try allocator.dupe(u8, table_name),
        .pascal_name = try allocator.dupe(u8, table_name), // will be pascal-cased below
        .columns = std.ArrayList(codegen.Column).empty,
        .allocator = allocator,
    };
    allocator.free(table.pascal_name);
    table.pascal_name = try pascalCaseConvert(allocator, table_name);

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const col_name = c.sqlite3_column_text(stmt, 1);
        const col_type = c.sqlite3_column_text(stmt, 2);
        const not_null = c.sqlite3_column_int(stmt, 3);
        const is_pk = c.sqlite3_column_int(stmt, 5);

        try table.columns.append(allocator, codegen.Column{
            .name = try allocator.dupe(u8, std.mem.span(col_name)),
            .sql_type = try allocator.dupe(u8, std.mem.span(col_type)),
            .is_nullable = not_null == 0,
            .is_primary_key = is_pk > 0,
            .is_auto_increment = is_pk > 0 and std.mem.startsWith(u8, std.mem.span(col_type), "INTEGER"),
            .default_value = null,
            .max_length = null,
        });
    }

    const sub = try subsystemOf(allocator, table.name);
    defer allocator.free(sub);
    try writeGeneratedFiles(allocator, &table, sub);
}

fn handleCrudFromDsn(allocator: std.mem.Allocator, dsn_url: []const u8) !void {
    var tables = extractTables: {
        if (std.mem.startsWith(u8, dsn_url, "postgres://") or std.mem.startsWith(u8, dsn_url, "postgresql://")) {
            if (!zf_cfg.enable_pg) {
                std.debug.print("PostgreSQL support not enabled. Rebuild with: zig build install-zf -Denable-pg\n", .{});
                return error.PgNotEnabled;
            }
            const csql_pg = @import("csql_pg.zig");
            var dsn = try csql_pg.Dsn.parse(allocator, dsn_url);
            defer dsn.deinit(allocator);
            break :extractTables try csql_pg.extractFromDb(allocator, dsn);
        } else if (std.mem.startsWith(u8, dsn_url, "mysql://")) {
            if (!zf_cfg.enable_my) {
                std.debug.print("MySQL support not enabled. Rebuild with: zig build install-zf -Denable-mysql\n", .{});
                return error.MyNotEnabled;
            }
            const csql_my = @import("csql_my.zig");
            var dsn = try csql_my.Dsn.parse(allocator, dsn_url);
            defer dsn.deinit(allocator);
            break :extractTables try csql_my.extractFromDb(allocator, dsn);
        } else {
            std.debug.print("Unknown DSN scheme. Use postgres:// or mysql://\n", .{});
            return error.InvalidDsn;
        }
    };
    defer {
        for (tables.items) |*t| t.deinit();
        tables.deinit(allocator);
    }

    // Same flow as handleCrudFromSql after extraction
    const pkg = try codegen.generateMigrationPackage(allocator, tables.items);
    defer allocator.free(pkg);
    const out_path = try std.fmt.allocPrint(allocator, "zfinal_migration.zig", .{});
    defer allocator.free(out_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = pkg });
    std.debug.print("✅ Generated migration package: {s}\n", .{out_path});

    for (tables.items) |*table| {
        const sub = try subsystemOf(allocator, table.name);
        defer allocator.free(sub);
        try writeGeneratedFiles(allocator, table, sub);
    }
    try generateIntegrationTestEntry(allocator, tables.items);
}

fn handleCrudFromSql(allocator: std.mem.Allocator, sql_path: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, sql_path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    var content = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(content);
    const n = try std.Io.File.readPositionalAll(file, io, content, 0);
    content = content[0..n];

    // Step 1: Import SQL into temp SQLite DB and introspect schema
    // This is more reliable than hand-parsing — it validates SQL and gets exact types
    var tables = extractTables: {
        break :extractTables csql.extractFromSql(allocator, content) catch {
            // Fallback to hand-parser if DB extraction fails (e.g., non-SQLite syntax)
            std.debug.print("DB introspection failed, falling back to text parser\n", .{});
            break :extractTables try codegen.parseSqlFile(allocator, content);
        };
    };
    defer {
        for (tables.items) |*t| t.deinit();
        tables.deinit(allocator);
    }

    const method = "DB introspection";
    std.debug.print("{s}: {d} tables from {s}\n", .{ method, tables.items.len, sql_path });

    // Step 2: Generate combined migration package
    const pkg = try codegen.generateMigrationPackage(allocator, tables.items);
    defer allocator.free(pkg);

    const out_path = try std.fmt.allocPrint(allocator, "zfinal_migration.zig", .{});
    defer allocator.free(out_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = pkg });

    std.debug.print("✅ Generated migration package: {s}\n", .{out_path});

    // Step 3: Generate individual module files + integration tests
    for (tables.items) |*table| {
        const sub = try subsystemOf(allocator, table.name);
        defer allocator.free(sub);
        try writeGeneratedFiles(allocator, table, sub);
    }

    // Step 4: Generate integration test entry point
    try generateIntegrationTestEntry(allocator, tables.items);
}

fn writeGeneratedFiles(allocator: std.mem.Allocator, table: *codegen.Table, subsystem: []const u8) !void {
    // Shared deps.zig — only written once
    {
        const deps =
            \\const std = @import("std");
            \\const zfinal = @import("zfinal");
            \\pub var pool: zfinal.ConnectionPool = undefined;
            \\pub var tokenMgr: zfinal.TokenManager = undefined;
            \\pub var rateLimiter: zfinal.RateLimitHandler = undefined;
            \\
            \\pub fn initDeps(allocator: std.mem.Allocator, db_config: zfinal.DBConfig) !void {
            \\    tokenMgr = zfinal.TokenManager.init(allocator);
            \\    tokenMgr.setTTL(3600);
            \\    rateLimiter = zfinal.RateLimitHandler.init(allocator);
            \\    rateLimiter.max_requests = 100;
            \\    pool = zfinal.ConnectionPool.init(allocator, db_config, 10);
            \\    _ = pool.acquire() catch {};
            \\}
            \\
            \\pub const corsInterceptor = zfinal.CORSInterceptor;
            \\
            \\pub fn healthHandler(ctx: *zfinal.Context) !void {
            \\    try ctx.renderJson(.{ .status = "ok", .uptime = "See /health" });
            \\}
            \\
        ;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "src/deps.zig", .data = deps }) catch {};
    }

    const module_name = blk: {
        // If table has subsystem prefix (e.g., "system_users"), strip it for module name
        const raw = if (subsystem.len > 0 and table.name.len > subsystem.len + 1)
            table.name[subsystem.len + 1 ..]
        else
            table.name;
        break :blk try singularize(allocator, raw);
    };
    defer allocator.free(module_name);
    // Compute module dir: with subsystem prefix → nested, without → flat
    const module_dir = if (subsystem.len > 0)
        try std.fmt.allocPrint(allocator, "src/modules/{s}/{s}", .{ subsystem, module_name })
    else
        try std.fmt.allocPrint(allocator, "src/modules/{s}", .{module_name});
    defer allocator.free(module_dir);
    try ensureDir(allocator, module_dir);

    // deps.zig relative path: modules/<sub>/<name>/ → ../../.., modules/<name>/ → ../..
    const deps_prefix = if (subsystem.len > 0) "../../../" else "../../";

    // Determine naming from table columns (snake_case if any underscore found)
    const naming: codegen.JsonNaming = blk: {
        for (table.columns.items) |col| {
            if (std.mem.indexOfScalar(u8, col.name, '_') != null) break :blk .snake_case;
        }
        break :blk .camelCase;
    };

    // ── model.gen.zig (always overwrite) ──
    const model_gen = try codegen.generateModel(allocator, table, naming);
    defer allocator.free(model_gen);
    const model_gen_path = try std.fmt.allocPrint(allocator, "{s}/model.gen.zig", .{module_dir});
    defer allocator.free(model_gen_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = model_gen_path, .data = model_gen });
    std.debug.print("✅ Generated: {s}\n", .{model_gen_path});

    // ── ext/ dir for AI-written extension files ──
    const ext_dir = try std.fmt.allocPrint(allocator, "{s}/ext", .{module_dir});
    defer allocator.free(ext_dir);
    try ensureDir(allocator, ext_dir);

    // ── ext/model.zig (ext stub, only if not exists) ──
    const model_ext_path = try std.fmt.allocPrint(allocator, "{s}/ext/model.zig", .{module_dir});
    defer allocator.free(model_ext_path);
    if (std.Io.Dir.cwd().access(io, model_ext_path, .{})) |_| {
        std.debug.print("   Skip (exists): {s}\n", .{model_ext_path});
    } else |_| {
        const model_ext = try codegen.generateModelExt(allocator, table, module_name);
        defer allocator.free(model_ext);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = model_ext_path, .data = model_ext });
        std.debug.print("✅ Generated: {s}\n", .{model_ext_path});
    }

    // ── ext/handler.zig (ext stub, only if not exists) ──
    const handler_ext_path = try std.fmt.allocPrint(allocator, "{s}/ext/handler.zig", .{module_dir});
    defer allocator.free(handler_ext_path);
    if (std.Io.Dir.cwd().access(io, handler_ext_path, .{})) |_| {
        std.debug.print("   Skip (exists): {s}\n", .{handler_ext_path});
    } else |_| {
        const handler_ext = try codegen.generateHandlerExt(allocator, module_name);
        defer allocator.free(handler_ext);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = handler_ext_path, .data = handler_ext });
        std.debug.print("✅ Generated: {s}\n", .{handler_ext_path});
    }

    // ── service.gen.zig (always overwrite) ──
    const service_gen = try codegen.generateService(allocator, table);
    defer allocator.free(service_gen);
    const service_gen_path = try std.fmt.allocPrint(allocator, "{s}/service.gen.zig", .{module_dir});
    defer allocator.free(service_gen_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = service_gen_path, .data = service_gen });
    std.debug.print("✅ Generated: {s}\n", .{service_gen_path});

    // ── ext/service.zig (ext stub, only if not exists) ──
    const service_ext_path = try std.fmt.allocPrint(allocator, "{s}/ext/service.zig", .{module_dir});
    defer allocator.free(service_ext_path);
    if (std.Io.Dir.cwd().access(io, service_ext_path, .{})) |_| {
        std.debug.print("   Skip (exists): {s}\n", .{service_ext_path});
    } else |_| {
        const service_ext = try codegen.generateServiceExt(allocator, module_name);
        defer allocator.free(service_ext);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = service_ext_path, .data = service_ext });
        std.debug.print("✅ Generated: {s}\n", .{service_ext_path});
    }

    // Handler (generated)
    const hdlr = try codegen.generateHandler(allocator, table, deps_prefix);
    defer allocator.free(hdlr);
    const hdlr_gen_path = try std.fmt.allocPrint(allocator, "{s}/handler.gen.zig", .{module_dir});
    defer allocator.free(hdlr_gen_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = hdlr_gen_path, .data = hdlr });
    std.debug.print("✅ Generated: {s}\n", .{hdlr_gen_path});

    // Routes
    const routes = try codegen.generateRoutes(allocator, table);
    defer allocator.free(routes);
    const routes_path = try std.fmt.allocPrint(allocator, "{s}/routes.zig", .{module_dir});
    defer allocator.free(routes_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = routes_path, .data = routes });
    std.debug.print("✅ Generated: {s}\n", .{routes_path});

    // ── test.gen.zig (always overwrite) ──
    try ensureDir(allocator, "test/gen");
    const test_code = try codegen.generateTest(allocator, table);
    defer allocator.free(test_code);
    const test_gen_path = try std.fmt.allocPrint(allocator, "test/gen/{s}_test.gen.zig", .{module_name});
    defer allocator.free(test_gen_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = test_gen_path, .data = test_code });
    std.debug.print("✅ Generated test: {s}\n", .{test_gen_path});

    // ── Integration test (full-stack: handler→service→model→DB) ──
    try ensureDir(allocator, "test/integration");
    const int_test = try codegen.generateIntegrationTest(allocator, table, module_name);
    defer allocator.free(int_test);
    const int_test_path = try std.fmt.allocPrint(allocator, "test/integration/{s}_int_test.gen.zig", .{module_name});
    defer allocator.free(int_test_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = int_test_path, .data = int_test });
    std.debug.print("✅ Generated integration test: {s}\n", .{int_test_path});
}

/// Generate integration test runner that references all module tests
fn generateIntegrationTestEntry(allocator: std.mem.Allocator, tables: []codegen.Table) !void {
    try ensureDir(allocator, "test/integration");
    var imports = std.ArrayList(u8).empty;
    defer imports.deinit(allocator);

    for (tables) |*table| {
        const mn = singularize(allocator, table.name) catch continue;
        defer allocator.free(mn);
        const line_i = try std.fmt.allocPrint(allocator, "const _{s}_test = @import(\"{s}_int_test.gen.zig\");\n", .{ mn, mn });
        defer allocator.free(line_i);
        try imports.appendSlice(allocator, line_i);
    }

    const content = try std.fmt.allocPrint(allocator,
        \\// @generated by zf crud:sql — integration test runner
        \\// Runs all per-table integration tests. DB connectivity, CRUD chain, handler import.
        \\const std = @import("std");
        \\const testing = std.testing;
        \\
        \\{s}
        \\test "integration: all tables import OK" {{
        \\    _ = testing;
        \\    // All per-table tests are imported above.
        \\    // Run with: zig build test --test-filter integration
        \\    std.debug.print("Integration test runner loaded {{d}} modules\n", .{{{d}}});
        \\}}
    , .{ imports.items, tables.len });
    defer allocator.free(content);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "test/integration/runner.zig", .data = content });
    std.debug.print("✅ Generated integration runner: test/integration/runner.zig\n", .{});
}

/// Extract subsystem prefix from table name. system_users → "system", users → "".
fn subsystemOf(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '_')) |pos| {
        if (pos > 0 and pos < name.len - 1) return alloc.dupe(u8, name[0..pos]);
    }
    return alloc.dupe(u8, "");
}

fn singularize(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (name.len > 3 and std.mem.endsWith(u8, name, "ies")) {
        var r = try allocator.alloc(u8, name.len - 3);
        @memcpy(r, name[0 .. name.len - 3]);
        r = try std.fmt.allocPrint(allocator, "{s}y", .{r[0 .. name.len - 3]});
        return r;
    }
    if (name.len > 1 and name[name.len - 1] == 's' and name[name.len - 2] != 's') return allocator.dupe(u8, name[0 .. name.len - 1]);
    return allocator.dupe(u8, name);
}

fn ensureDir(allocator: std.mem.Allocator, path: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, path) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.debug.print("Failed to create directory {s}: {}\n", .{ path, err });
            return err;
        }
    };
    _ = allocator;
}

fn pascalCaseConvert(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    var cap = true;
    for (name) |c| {
        if (c == '_' or c == '-') { cap = true; continue; }
        try result.append(allocator, if (cap) std.ascii.toUpper(c) else c);
        cap = false;
    }
    if (result.items.len > 0) result.items[0] = std.ascii.toUpper(result.items[0]);
    return result.toOwnedSlice(allocator);
}

fn copyPluginFile(allocator: std.mem.Allocator, filename: []const u8) !void {
    const dest_path = try std.fmt.allocPrint(allocator, "src/plugin/{s}", .{filename});
    defer allocator.free(dest_path);

    // Check if we are in the ZFinal repo
    const src_path = try std.fmt.allocPrint(allocator, "src/plugin/{s}", .{filename});
    defer allocator.free(src_path);

    std.Io.Dir.cwd().access(io, src_path, .{}) catch {
        std.debug.print("⚠️  Could not find source plugin file: {s}\n", .{src_path});
        std.debug.print("Please ensure you are running this from the ZFinal repository root for now.\n", .{});
        return;
    };

    try std.Io.Dir.cwd().copyFile(src_path, std.Io.Dir.cwd(), dest_path, io, .{});
    std.debug.print("✅ Installed plugin: {s}\n", .{dest_path});
}
