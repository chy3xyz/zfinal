const std = @import("std");
const templates = @import("templates.zig");
const codegen = @import("codegen");
const csql = @import("csql.zig");
const zf_cfg = @import("zf_cfg");
const sqlite_c = @import("c_sqlite3");

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
    check,
    upgrade,
    life,
    admin,
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
                std.debug.print("Usage: {s} new <project_name> [--clean]\n", .{argv0});
                std.debug.print("  --clean  Skip demo files (handler/user.zig, model/user.zig)\n", .{});
                return;
            }
            const clean = args.len > 3 and std.mem.eql(u8, args[3], "--clean");
            try createProject(allocator, args[2], clean);
        },
        .generate => {
            if (args.len < 4) {
                std.debug.print("Usage: {s} generate <type> <name> [--json]\n", .{args[0]});
                std.debug.print("Types: controller, model, interceptor, plugin\n", .{});
                std.debug.print("      handler, service, middleware, task\n", .{});
                std.debug.print("Flags: --json   Emit machine-readable manifest.\n", .{});
                return;
            }
            const json_mode = hasFlag(args, "--json");
            try generateCode(allocator, args[2], args[3], false, json_mode);
        },
        .api => {
            if (args.len < 3) {
                std.debug.print("Usage: {s} api <name>\n", .{args[0]});
                std.debug.print("Generate API handler (JSON output)\n", .{});
                return;
            }
            try generateCode(allocator, "handler", args[2], true, false);
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
            std.debug.print("ZFinal CLI (zf) version {s}\n", .{zf_cfg.version});
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
                std.debug.print("Usage: {s} crud:sql <sql_file> [project_name] [--force] [--json] [--admin]\n", .{args[0]});
                std.debug.print("  project_name  Optional. Creates project dir and generates inside it.\n", .{});
                std.debug.print("  --force       Overwrite existing files instead of generating .gen.new\n", .{});
                std.debug.print("  --json        Emit machine-readable manifest for AI agents.\n", .{});
                std.debug.print("  --admin       Also emit vben-style admin HTML (htmx + alpine + tailwind, CDN).\n", .{});
                return;
            }
            const project_name = if (args.len > 3 and !std.mem.eql(u8, args[3], "--force") and !std.mem.eql(u8, args[3], "--json") and !std.mem.eql(u8, args[3], "--admin")) args[3] else null;
            const force = hasFlag(args, "--force");
            const json_mode = hasFlag(args, "--json");
            const admin_mode = hasFlag(args, "--admin");
            try handleCrudFromSql(allocator, args[2], project_name, force, json_mode, admin_mode);
        },
        .admin => {
            if (args.len < 3) {
                std.debug.print("Usage: {s} admin <sql_file> [--out <dir>]\n", .{args[0]});
                std.debug.print("  Generate vben-style admin HTML (htmx + alpine + tailwind, CDN).\n", .{});
                std.debug.print("  --out <dir>   Output directory (default: src/modules)\n", .{});
                return;
            }
            const out_dir = blk: {
                var i: usize = 3;
                while (i + 1 < args.len) : (i += 1) {
                    if (std.mem.eql(u8, args[i], "--out")) break :blk args[i + 1];
                }
                break :blk "src/modules";
            };
            try handleAdmin(allocator, args[2], out_dir);
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
        .check => {
            try handleCheck(allocator);
        },
        .upgrade => {
            try handleUpgrade(allocator);
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
    if (std.mem.eql(u8, cmd, "admin")) return .admin;
    if (std.mem.eql(u8, cmd, "crud:dsn")) return .crud_dsn;
    if (std.mem.eql(u8, cmd, "check")) return .check;
    if (std.mem.eql(u8, cmd, "upgrade")) return .upgrade;
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
    std.debug.print("  crud:sql <file> [name]  Generate from .sql file. Optional project name creates dir.\n", .{});
    std.debug.print("  admin <file>            Generate vben-style admin HTML (htmx + alpine + tailwind, CDN)\n", .{});
    std.debug.print("  check                   Audit project for AI compliance (gen/ext boundaries)\n", .{});
    std.debug.print("  upgrade                 Upgrade zfinal dependency to latest release\n", .{});
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

fn createProject(allocator: std.mem.Allocator, project_name: []const u8, clean: bool) !void {
    const cwd = std.Io.Dir.cwd();

    // Create project directory
    try cwd.createDirPath(io, project_name);
    var project_dir = try cwd.openDir(io, project_name, .{});
    defer project_dir.close(io);

    std.debug.print("\nCreating project: {s}\n", .{project_name});

    // Root: build.zig + build.zig.zon + CLAUDE.md
    const build_zig_content = try std.fmt.allocPrint(allocator, templates.build_zig, .{ "../zfinal/src/main.zig", project_name });
    defer allocator.free(build_zig_content);
    try writeFile(project_dir, "build.zig", build_zig_content);

    const app_name = std.fs.path.basename(project_name);
    const build_zon_content = try std.fmt.allocPrint(allocator, templates.build_zig_zon, .{app_name});
    defer allocator.free(build_zon_content);
    try writeFile(project_dir, "build.zig.zon", build_zon_content);

    const claude_md_content = try std.fmt.allocPrint(allocator, templates.claude_md, .{project_name});
    defer allocator.free(claude_md_content);
    try writeFile(project_dir, "CLAUDE.md", claude_md_content);

    // AI tool configs (.claude/, .opencode/, .cursor/)
    try writeAiConfigs(allocator, project_dir);

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
    if (clean) {
        try writeFile(src_dir, "routes.zig",
            \\const zfinal = @import("zfinal");
            \\const App = @import("App.zig").App;
            \\
            \\pub fn register(app: *App) !void {
            \\    // zf crud:sql adds routes here
            \\    _ = app;
            \\}
        );
    } else {
        try writeFile(src_dir, "routes.zig", templates.routes_zig);
    }

    // src/handler/
    try src_dir.createDirPath(io, "handler");
    if (!clean) {
        var handler_dir = try src_dir.openDir(io, "handler", .{});
        defer handler_dir.close(io);
        const index_content = try std.fmt.allocPrint(allocator, templates.handler_index_zig, .{project_name});
        defer allocator.free(index_content);
        try writeFile(handler_dir, "index.zig", index_content);
        try writeFile(handler_dir, "user.zig", templates.handler_user_zig);
    }

    // src/service/ — business logic layer
    try src_dir.createDirPath(io, "service");

    // src/model/
    try src_dir.createDirPath(io, "model");
    if (!clean) {
        var model_dir = try src_dir.openDir(io, "model", .{});
        defer model_dir.close(io);
        try writeFile(model_dir, "user.zig", templates.model_user_zig);
    }

    // src/middleware/
    try src_dir.createDirPath(io, "middleware");
    if (!clean) {
        var middleware_dir = try src_dir.openDir(io, "middleware", .{});
        defer middleware_dir.close(io);
        try writeFile(middleware_dir, "auth.zig", templates.middleware_auth_zig);
    }

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

fn generateCode(allocator: std.mem.Allocator, gen_type: []const u8, name: []const u8, is_api: bool, json_mode: bool) !void {
    if (name.len == 0) {
        std.debug.print("Error: Name is required\n", .{});
        return;
    }

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    if (std.mem.eql(u8, gen_type, "handler")) {
        try generateHandler(allocator, name, is_api);
        try buf.appendSlice(allocator, "src/handler/");
        try buf.appendSlice(allocator, name);
        try buf.appendSlice(allocator, ".zig");
    } else if (std.mem.eql(u8, gen_type, "model")) {
        try generateModel(allocator, name);
        try buf.appendSlice(allocator, "src/model/");
        try buf.appendSlice(allocator, name);
        try buf.appendSlice(allocator, ".zig");
    } else if (std.mem.eql(u8, gen_type, "middleware")) {
        try generateMiddleware(allocator, name);
        try buf.appendSlice(allocator, "src/middleware/");
        try buf.appendSlice(allocator, name);
        try buf.appendSlice(allocator, ".zig");
    } else if (std.mem.eql(u8, gen_type, "service")) {
        try generateService(allocator, name);
        try buf.appendSlice(allocator, "src/service/");
        try buf.appendSlice(allocator, name);
        try buf.appendSlice(allocator, ".zig");
    } else if (std.mem.eql(u8, gen_type, "task")) {
        try generateTask(allocator, name);
        try buf.appendSlice(allocator, "src/task/");
        try buf.appendSlice(allocator, name);
        try buf.appendSlice(allocator, ".zig");
    } else if (std.mem.eql(u8, gen_type, "controller")) {
        // Backward compat: map controller → handler
        try generateHandler(allocator, name, is_api);
        try buf.appendSlice(allocator, "src/handler/");
        try buf.appendSlice(allocator, name);
        try buf.appendSlice(allocator, ".zig");
    } else {
        std.debug.print("Unknown type: {s}\n", .{gen_type});
        std.debug.print("Available: handler, model, middleware, service, task\n", .{});
        return;
    }

    if (json_mode) {
        var out_buf = std.ArrayList(u8).empty;
        defer out_buf.deinit(allocator);
        try out_buf.appendSlice(allocator, "{\n");
        try out_buf.appendSlice(allocator, "  \"$schema\": \"https://zfinal.dev/schemas/manifest-1.json\",\n");
        try out_buf.appendSlice(allocator, "  \"version\": \"0.9.0\",\n");
        try out_buf.appendSlice(allocator, "  \"generator\": \"zf g\",\n");
        try out_buf.appendSlice(allocator, "  \"type\": \"");
        try appendJsonString(allocator, &out_buf, gen_type);
        try out_buf.appendSlice(allocator, "\",\n");
        try out_buf.appendSlice(allocator, "  \"name\": \"");
        try appendJsonString(allocator, &out_buf, name);
        try out_buf.appendSlice(allocator, "\",\n");
        try out_buf.appendSlice(allocator, "  \"file\": \"");
        try appendJsonString(allocator, &out_buf, buf.items);
        try out_buf.appendSlice(allocator, "\",\n");
        try out_buf.appendSlice(allocator, "  \"next_steps\": [\n");
        try out_buf.appendSlice(allocator, "    \"Fill the generated handler/service body\",\n");
        try out_buf.appendSlice(allocator, "    \"Add route registration: try app.get(\\\"/<path>\\\", <Name>Handler.<action>)\",\n");
        try out_buf.appendSlice(allocator, "    \"Run: zf check && zig build test\"\n");
        try out_buf.appendSlice(allocator, "  ]\n");
        try out_buf.appendSlice(allocator, "}\n");
        var out = std.Io.File.stdout();
        try out.writeStreamingAll(io, out_buf.items);
    }
}

fn generateHandler(allocator: std.mem.Allocator, name: []const u8, is_api: bool) !void {
    std.Io.Dir.cwd().access(io, "src/handler", .{}) catch {
        std.debug.print("Error: src/handler directory not found. Run 'zf new' first.\n", .{});
        return;
    };

    const name_lower = try std.ascii.allocLowerString(allocator, name);
    defer allocator.free(name_lower);

    // Single-file generation (no gen+ext split for AI-maintained code)
    const filename = try std.fmt.allocPrint(allocator, "src/handler/{s}.zig", .{name_lower});
    defer allocator.free(filename);

    const content = try std.fmt.allocPrint(allocator,
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
    std.debug.print("✅ Generated {s} handler: {s}\n", .{ mode_str, filename });

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

    // Single-file generation (AI-maintained, no ext/ split)
    const filename = try std.fmt.allocPrint(allocator, "src/model/{s}.zig", .{name_lower});
    defer allocator.free(filename);

    const model_name = try capitalizeOwned(allocator, name);
    defer allocator.free(model_name);
    const table_name = try std.fmt.allocPrint(allocator, "{s}s", .{name_lower});
    defer allocator.free(table_name);

    const content = try std.fmt.allocPrint(allocator,
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
    defer allocator.free(content);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = filename, .data = content });
    std.debug.print("✅ Generated model: {s}\n", .{filename});
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

const admin_templates = @import("admin_templates.zig");

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const stat = try f.stat(io);
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    const chunks = [_][]u8{buf};
    _ = try f.readStreaming(io, &chunks);
    return buf;
}

/// Generate vben-style admin HTML files for every table in a SQL file.
/// Each table produces 4 files: admin.html, admin_form.html, admin_row.html
/// plus a shared layout.html at the output root.
fn handleAdmin(allocator: std.mem.Allocator, sql_path: []const u8, out_dir: []const u8) !void {
    std.debug.print("📋 zf admin — generating vben-style UI for {s}\n", .{sql_path});
    std.debug.print("   output: {s}/\n", .{out_dir});

    const sql_text = readFileAlloc(allocator, sql_path) catch |e| {
        std.debug.print("error: cannot read {s}: {t}\n", .{ sql_path, e });
        return e;
    };
    defer allocator.free(sql_text);

    var tables = codegen.parseSqlFile(allocator, sql_text) catch |e| {
        std.debug.print("error: failed to parse SQL: {t}\n", .{e});
        return e;
    };
    defer {
        for (tables.items) |*t| t.deinit();
        tables.deinit(allocator);
    }
    if (tables.items.len == 0) {
        std.debug.print("error: no CREATE TABLE found in {s}\n", .{sql_path});
        return error.NoTables;
    }

    // Ensure output directory exists
    const dir = std.Io.Dir.createDirPathOpen(.cwd(), io, out_dir, .{}) catch |e| {
        std.debug.print("error: cannot create {s}: {t}\n", .{ out_dir, e });
        return e;
    };
    defer std.Io.Dir.close(dir, io);

    var written: usize = 0;
    for (tables.items) |*table| {
        const files = admin_templates.renderAll(allocator, table) catch |e| {
            std.debug.print("error rendering {s}: {t}\n", .{ table.name, e });
            return e;
        };
        defer files.deinit(allocator);

        const module_dir_path = try std.fmt.allocPrint(allocator, "{s}", .{table.name});
        defer allocator.free(module_dir_path);
        const module_dir = std.Io.Dir.createDirPathOpen(dir, io, module_dir_path, .{}) catch |e| {
            std.debug.print("error: cannot create {s}/{s}: {t}\n", .{ out_dir, table.name, e });
            return e;
        };
        defer std.Io.Dir.close(module_dir, io);

        try writeFile(module_dir, "admin.html", files.list);
        try writeFile(module_dir, "admin_form.html", files.form);
        try writeFile(module_dir, "admin_row.html", files.row);
        written += 1;
    }

    // Shared layout at out_dir root
    if (tables.items.len > 0) {
        const layout_files = admin_templates.renderAll(allocator, &tables.items[0]) catch return error.RenderLayout;
        defer layout_files.deinit(allocator);
        try writeFile(dir, "admin_layout.html", layout_files.layout);
    }

    std.debug.print("✅ Generated {d} module(s) × 3 admin files + 1 shared layout\n", .{written});
    std.debug.print("   Edit ai-edit-zones in each file to customize.\n", .{});
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
    var db: ?*sqlite_c.sqlite3 = null;
    const rc = sqlite_c.sqlite3_open(db_path.ptr, &db);
    if (rc != sqlite_c.SQLITE_OK) {
        std.debug.print("Failed to open database: {s}\n", .{db_path});
        return;
    }
    defer _ = sqlite_c.sqlite3_close(db);

    // Read column info via PRAGMA
    var stmt: ?*sqlite_c.sqlite3_stmt = null;
    var pragma_buf: [256]u8 = undefined;
    const pragma = try std.fmt.bufPrint(&pragma_buf, "PRAGMA table_info({s})", .{table_name});
    pragma_buf[pragma.len] = 0;
    const pragma_sql: [:0]const u8 = pragma_buf[0..pragma.len :0];
    _ = sqlite_c.sqlite3_prepare_v2(db, pragma_sql.ptr, @intCast(pragma_sql.len + 1), &stmt, null);
    if (stmt == null) {
        std.debug.print("Table '{s}' not found in database.\n", .{table_name});
        return;
    }
    defer _ = sqlite_c.sqlite3_finalize(stmt);

    var table = codegen.Table{
        .name = try allocator.dupe(u8, table_name),
        .pascal_name = try allocator.dupe(u8, table_name), // will be pascal-cased below
        .columns = std.ArrayList(codegen.Column).empty,
        .allocator = allocator,
    };
    allocator.free(table.pascal_name);
    table.pascal_name = try pascalCaseConvert(allocator, table_name);

    while (sqlite_c.sqlite3_step(stmt) == sqlite_c.SQLITE_ROW) {
        const col_name = sqlite_c.sqlite3_column_text(stmt, 1);
        const col_type = sqlite_c.sqlite3_column_text(stmt, 2);
        const not_null = sqlite_c.sqlite3_column_int(stmt, 3);
        const is_pk = sqlite_c.sqlite3_column_int(stmt, 5);

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

    const sub = try modulePath(allocator, table.name);
    defer allocator.free(sub);
    try writeGeneratedFiles(allocator, &table, sub, false);
}

fn handleCrudFromDsn(allocator: std.mem.Allocator, dsn_url: []const u8) !void {
    // Auto-bootstrap if needed
    // Check if project exists by trying to open build.zig.zon
    const zon_file = std.Io.Dir.cwd().openFile(io, "build.zig.zon", .{});
    if (zon_file) |f| {
        f.close(io);
    } else |_| {
        std.debug.print("⚡ Bootstrapping clean project...\n", .{});
        try bootstrapProject(allocator);
    }

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
        const mp = try modulePath(allocator, table.name);
        defer allocator.free(mp);
        try writeGeneratedFiles(allocator, table, mp, false);
    }
    try generateIntegrationTestEntry(allocator, tables.items);
}

fn handleCrudFromSql(allocator: std.mem.Allocator, sql_path: []const u8, project_name: ?[]const u8, force: bool, json_mode: bool, admin_mode: bool) !void {
    // Resolve SQL path to absolute before any chdir
    var resolved_sql: []const u8 = undefined;
    if (std.fs.path.isAbsolute(sql_path)) {
        resolved_sql = sql_path;
    } else {
        var cwd_buf: [4096]u8 = undefined;
        const cwd = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.CwdTooLong;
        resolved_sql = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ std.mem.sliceTo(cwd, 0), sql_path });
    }
    defer if (!std.fs.path.isAbsolute(sql_path)) allocator.free(resolved_sql);

    // If project name given, create directory and work inside it
    if (project_name) |name| {
        std.Io.Dir.cwd().createDirPath(io, name) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        const name_z = try allocator.allocSentinel(u8, name.len, 0);
        @memcpy(name_z, name);
        defer allocator.free(name_z);
        _ = std.c.chdir(name_z.ptr);
    }

    // Auto-bootstrap project if not already in one
    // Check if project exists by trying to open build.zig.zon
    const zon_file = std.Io.Dir.cwd().openFile(io, "build.zig.zon", .{});
    if (zon_file) |f| {
        f.close(io);
    } else |_| {
        std.debug.print("⚡ Bootstrapping clean project...\n", .{});
        try bootstrapProject(allocator);
    }

    const file = try std.Io.Dir.cwd().openFile(io, resolved_sql, .{});
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
        const mp = try modulePath(allocator, table.name);
        defer allocator.free(mp);
        try writeGeneratedFiles(allocator, table, mp, force);
    }

    // Step 4: Generate module manifest (auto-aggregates all module routes)
    try generateModuleManifest(allocator, tables.items);

    // Step 5: Generate integration test entry point
    try generateIntegrationTestEntry(allocator, tables.items);

    // Step 5b: Optionally emit vben-style admin HTML for each table
    if (admin_mode) {
        const out_dir: []const u8 = "src/modules";
        const dir = std.Io.Dir.createDirPathOpen(.cwd(), io, out_dir, .{}) catch |e| {
            std.debug.print("error: cannot create {s}: {t}\n", .{ out_dir, e });
            return e;
        };
        defer std.Io.Dir.close(dir, io);
        for (tables.items) |*table| {
            const files = admin_templates.renderAll(allocator, table) catch |e| {
                std.debug.print("error rendering admin for {s}: {t}\n", .{ table.name, e });
                return e;
            };
            defer files.deinit(allocator);
            const module_dir = std.Io.Dir.createDirPathOpen(dir, io, table.name, .{}) catch |e| {
                std.debug.print("error: cannot create {s}/{s}: {t}\n", .{ out_dir, table.name, e });
                return e;
            };
            defer std.Io.Dir.close(module_dir, io);
            try writeFile(module_dir, "admin.html", files.list);
            try writeFile(module_dir, "admin_form.html", files.form);
            try writeFile(module_dir, "admin_row.html", files.row);
        }
        // Shared layout
        if (tables.items.len > 0) {
            const layout_files = admin_templates.renderAll(allocator, &tables.items[0]) catch return error.RenderLayout;
            defer layout_files.deinit(allocator);
            try writeFile(dir, "admin_layout.html", layout_files.layout);
        }
        std.debug.print("✅ vben-style admin HTML emitted to {s}/\n", .{out_dir});
    }

    // Step 6: Emit machine-readable manifest for AI agents
    if (json_mode) {
        try emitJsonManifest(allocator, sql_path, tables.items);
    }
}

/// Emit a JSON manifest on stdout describing the generated artifacts.
/// AI agents parse this to know which files to edit and which fields to fill.
fn emitJsonManifest(allocator: std.mem.Allocator, sql_path: []const u8, tables: []codegen.Table) !void {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n");
    try buf.appendSlice(allocator, "  \"$schema\": \"https://zfinal.dev/schemas/manifest-1.json\",\n");
    try buf.appendSlice(allocator, "  \"version\": \"0.9.0\",\n");

    // sql_path
    try buf.appendSlice(allocator, "  \"sql_path\": \"");
    try appendJsonString(allocator, &buf, sql_path);
    try buf.appendSlice(allocator, "\",\n");

    try buf.appendSlice(allocator, "  \"tables\": [\n");
    for (tables, 0..) |*table, i| {
        if (i > 0) try buf.appendSlice(allocator, ",\n");
        try buf.appendSlice(allocator, "    {\n");
        try buf.appendSlice(allocator, "      \"name\": \"");
        try appendJsonString(allocator, &buf, table.name);
        try buf.appendSlice(allocator, "\",\n");
        try buf.appendSlice(allocator, "      \"pascal_name\": \"");
        try appendJsonString(allocator, &buf, table.pascal_name);
        try buf.appendSlice(allocator, "\",\n");

        // Files
        try buf.appendSlice(allocator, "      \"files\": {\n");
        try buf.appendSlice(allocator, "        \"model\": \"");
        try appendJsonString(allocator, &buf, table.name);
        try buf.appendSlice(allocator, "/model.zig\",\n");
        try buf.appendSlice(allocator, "        \"service\": \"");
        try appendJsonString(allocator, &buf, table.name);
        try buf.appendSlice(allocator, "/service.zig\",\n");
        try buf.appendSlice(allocator, "        \"handler\": \"");
        try appendJsonString(allocator, &buf, table.name);
        try buf.appendSlice(allocator, "/handler.zig\",\n");
        try buf.appendSlice(allocator, "        \"routes\": \"");
        try appendJsonString(allocator, &buf, table.name);
        try buf.appendSlice(allocator, "/routes.zig\"\n");
        try buf.appendSlice(allocator, "      },\n");

        // AI edit zones
        try buf.appendSlice(allocator, "      \"ai_edit_zones\": [\n");
        try buf.appendSlice(allocator, "        { \"file\": \"service.zig\", \"markers\": [\"// ai-edit-zone: business rules\", \"// ai-edit-zone: validation\"], \"purpose\": \"custom business logic beyond generated CRUD\" },\n");
        try buf.appendSlice(allocator, "        { \"file\": \"handler.zig\", \"markers\": [\"// ai-edit-zone: auth check\", \"// ai-edit-zone: response shaping\"], \"purpose\": \"per-route auth, response transformation\" }\n");
        try buf.appendSlice(allocator, "      ],\n");

        // Fields
        try buf.appendSlice(allocator, "      \"fields\": [\n");
        for (table.columns.items, 0..) |col, j| {
            if (j > 0) try buf.appendSlice(allocator, ",\n");
            try buf.appendSlice(allocator, "        { \"name\": \"");
            try appendJsonString(allocator, &buf, col.name);
            try buf.appendSlice(allocator, "\", \"sql_type\": \"");
            try appendJsonString(allocator, &buf, col.sql_type);
            try buf.appendSlice(allocator, "\", \"nullable\": ");
            try buf.appendSlice(allocator, if (col.is_nullable) "true" else "false");
            try buf.appendSlice(allocator, ", \"primary_key\": ");
            try buf.appendSlice(allocator, if (col.is_primary_key) "true" else "false");

            // UI metadata for admin form generation (PR 3)
            try buf.appendSlice(allocator, ", \"ui\": { \"input\": \"");
            try appendJsonString(allocator, &buf, uiInputForType(col.sql_type));
            try buf.appendSlice(allocator, "\", \"label_zh\": \"");
            try appendJsonString(allocator, &buf, col.name); // default label = column name
            try buf.appendSlice(allocator, "\", \"required\": ");
            try buf.appendSlice(allocator, if (col.is_nullable) "false" else "true");
            try buf.appendSlice(allocator, " }");

            try buf.appendSlice(allocator, " }");
        }
        try buf.appendSlice(allocator, "\n      ]\n");
        try buf.appendSlice(allocator, "    }");
    }
    try buf.appendSlice(allocator, "\n  ],\n");

    // Next steps for the AI
    try buf.appendSlice(allocator, "  \"next_steps\": [\n");
    try buf.appendSlice(allocator, "    \"Review each handler.zig — fill ai-edit-zones for auth, response shaping, custom errors\",\n");
    try buf.appendSlice(allocator, "    \"Add routes via zf route <Table> /<path> (if not auto-generated)\",\n");
    try buf.appendSlice(allocator, "    \"Run: zf check && zig build test\",\n");
    try buf.appendSlice(allocator, "    \"Commit when all checks pass\"\n");
    try buf.appendSlice(allocator, "  ]\n");
    try buf.appendSlice(allocator, "}\n");

    // Write to stdout so AI can pipe
    var out = std.Io.File.stdout();
    try out.writeStreamingAll(io, buf.items);
}

/// Map SQL type to HTML input type for the admin form. Same
/// heuristic as admin_templates.inputHtmlForColumn but exposed
/// in the manifest so AI agents can read the UI contract.
fn uiInputForType(sql_type: []const u8) []const u8 {
    // Cheap uppercase copy
    var upper_buf: [32]u8 = undefined;
    const n = @min(sql_type.len, upper_buf.len);
    for (0..n) |i| upper_buf[i] = std.ascii.toUpper(sql_type[i]);
    const upper = upper_buf[0..n];

    if (std.mem.eql(u8, upper, "INTEGER") or std.mem.eql(u8, upper, "INT")) return "number";
    if (std.mem.eql(u8, upper, "REAL") or std.mem.eql(u8, upper, "FLOAT") or std.mem.eql(u8, upper, "DOUBLE")) return "number";
    if (std.mem.eql(u8, upper, "BOOLEAN") or std.mem.eql(u8, upper, "BOOL")) return "checkbox";
    if (std.mem.eql(u8, upper, "DATE")) return "date";
    if (std.mem.eql(u8, upper, "DATETIME") or std.mem.eql(u8, upper, "TIMESTAMP")) return "datetime-local";
    return "text";
}

/// Append a JSON-escaped string (no surrounding quotes).
pub fn appendJsonString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x08 => try buf.appendSlice(allocator, "\\b"),
            0x0C => try buf.appendSlice(allocator, "\\f"),
            else => if (c < 0x20) {
                var esc: [8]u8 = undefined;
                const len = try std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c});
                try buf.appendSlice(allocator, len);
            } else {
                const ch: [1]u8 = .{c};
                try buf.appendSlice(allocator, &ch);
            },
        }
    }
}

/// Generate modules/manifest.gen.zig — auto-discovers and registers all module routes.
fn generateModuleManifest(allocator: std.mem.Allocator, tables: []codegen.Table) !void {
    try ensureDir(allocator, "src/modules");
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\// @generated — DO NOT EDIT. AI: regenerated by zf crud:sql.
        \\
    );

    for (tables, 0..) |*table, i| {
        const mp = try modulePath(allocator, table.name);
        defer allocator.free(mp);
        const line = try std.fmt.allocPrint(allocator,
            \\const _m{d} = @import("{s}/routes.zig");
        , .{ i, mp });
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }

    try buf.appendSlice(allocator,
        \\
        \\
        \\pub fn registerAll(app: anytype) !void {
    );

    for (tables, 0..) |*table, i| {
        const mp = try modulePath(allocator, table.name);
        defer allocator.free(mp);
        const line = try std.fmt.allocPrint(allocator, "    try _m{d}.register(app);\n", .{i});
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }

    try buf.appendSlice(allocator, "}\n");

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "src/modules/manifest.gen.zig", .data = buf.items });
    std.debug.print("✅ Generated module manifest: src/modules/manifest.gen.zig\n", .{});
}

fn writeGeneratedFiles(allocator: std.mem.Allocator, table: *codegen.Table, module_path: []const u8, force_overwrite: bool) !void {
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

    // module_path is like "system/dict/data" or "order" — use directly as dir
    const module_dir = try std.fmt.allocPrint(allocator, "src/modules/{s}", .{module_path});
    defer allocator.free(module_dir);
    try ensureDir(allocator, module_dir);

    // module_name for file naming: last segment of path ("data" from "system/dict/data")
    const module_name = blk: {
        if (std.mem.lastIndexOfScalar(u8, module_path, '/')) |pos| {
            break :blk try singularize(allocator, module_path[pos + 1 ..]);
        }
        break :blk try singularize(allocator, module_path);
    };
    defer allocator.free(module_name);

    // deps.zig relative path: count '/' in module_path, each level = one "../"
    var depth: usize = 2; // src/modules/ = 2 levels from project root
    for (module_path) |c| {
        if (c == '/') depth += 1;
    }
    var deps_buf: [64]u8 = undefined;
    var deps_len: usize = 0;
    for (0..depth) |_| {
        @memcpy(deps_buf[deps_len..][0..3], "../");
        deps_len += 3;
    }
    const deps_prefix = deps_buf[0..deps_len];

    // Determine naming from table columns (snake_case if any underscore found)
    const naming: codegen.JsonNaming = blk: {
        for (table.columns.items) |col| {
            if (std.mem.indexOfScalar(u8, col.name, '_') != null) break :blk .snake_case;
        }
        break :blk .camelCase;
    };

    // ── model.zig ──
    const model_code = try codegen.generateModel(allocator, table, naming);
    defer allocator.free(model_code);
    const model_path = try std.fmt.allocPrint(allocator, "{s}/model.zig", .{module_dir});
    defer allocator.free(model_path);
    try safeWrite(allocator, model_path, model_code, force_overwrite);

    // ── service.zig ──
    const service_code = try codegen.generateService(allocator, table);
    defer allocator.free(service_code);
    const service_path = try std.fmt.allocPrint(allocator, "{s}/service.zig", .{module_dir});
    defer allocator.free(service_path);
    try safeWrite(allocator, service_path, service_code, force_overwrite);

    // ── handler.zig ──
    const hdlr = try codegen.generateHandler(allocator, table, deps_prefix);
    defer allocator.free(hdlr);
    const hdlr_path = try std.fmt.allocPrint(allocator, "{s}/handler.zig", .{module_dir});
    defer allocator.free(hdlr_path);
    try safeWrite(allocator, hdlr_path, hdlr, force_overwrite);

    // Routes
    const routes = try codegen.generateRoutes(allocator, table);
    defer allocator.free(routes);
    const routes_path = try std.fmt.allocPrint(allocator, "{s}/routes.zig", .{module_dir});
    defer allocator.free(routes_path);
    try safeWrite(allocator, routes_path, routes, force_overwrite);

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
        \\// @generated — DO NOT EDIT. AI: runner is auto-generated, edit per-table tests in ext/.
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

/// Bootstrap minimal project in CWD — no demo files, ready for zf crud:sql.
fn bootstrapProject(allocator: std.mem.Allocator) !void {
    const cwd = std.Io.Dir.cwd();

    // build.zig
    const build_zig_content = try std.fmt.allocPrint(allocator, templates.build_zig, .{ "../zfinal/src/main.zig", "app" });
    defer allocator.free(build_zig_content);
    try writeFile(cwd, "build.zig", build_zig_content);

    // build.zig.zon
    const build_zon_content = try std.fmt.allocPrint(allocator, templates.build_zig_zon, .{"app"});
    defer allocator.free(build_zon_content);
    try writeFile(cwd, "build.zig.zon", build_zon_content);

    // CLAUDE.md
    const claude_content = try std.fmt.allocPrint(allocator, templates.claude_md, .{"app"});
    defer allocator.free(claude_content);
    try writeFile(cwd, "CLAUDE.md", claude_content);

    // src/
    try cwd.createDirPath(io, "src");
    var src_dir = try cwd.openDir(io, "src", .{});
    defer src_dir.close(io);

    // src/main.zig
    const main_content = try std.fmt.allocPrint(allocator, templates.main_zig, .{"app"});
    defer allocator.free(main_content);
    try writeFile(src_dir, "main.zig", main_content);

    // src/App.zig
    try writeFile(src_dir, "App.zig", templates.app_zig);

    // src/config.zig
    try writeFile(src_dir, "config.zig", templates.config_zig);

    // src/routes.zig — empty, zf crud:sql will append routes
    try writeFile(src_dir, "routes.zig",
        \\const zfinal = @import("zfinal");
        \\const App = @import("App.zig").App;
        \\
        \\pub fn register(app: *App) !void {
        \\    // zf crud:sql adds routes here
        \\    _ = app;
        \\}
    );

    // src/common/
    try src_dir.createDirPath(io, "common");
    var common_dir = try src_dir.openDir(io, "common", .{});
    defer common_dir.close(io);
    try writeFile(common_dir, "constants.zig", templates.common_constants_zig);
    try writeFile(common_dir, "errors.zig", templates.common_errors_zig);

    // src/validator/
    try src_dir.createDirPath(io, "validator");
    var validator_dir = try src_dir.openDir(io, "validator", .{});
    defer validator_dir.close(io);
    try writeFile(validator_dir, "validate.zig", templates.validator_validate);

    // src/task/
    try src_dir.createDirPath(io, "task");
    var task_dir = try src_dir.openDir(io, "task", .{});
    defer task_dir.close(io);
    try writeFile(task_dir, "runner.zig", templates.task_runner);

    // test/
    try cwd.createDirPath(io, "test");
    try cwd.createDirPath(io, "test/handler");

    // AI tool configs (.claude/, .opencode/, .cursor/)
    try writeAiConfigs(allocator, cwd);

    std.debug.print("✅ Clean project bootstrapped (no demo files)\n\n", .{});
}

/// Compute module path from table name. Splits on ALL underscores.
/// system_dict_data → "system/dict/data", system_users → "system/user", orders → "order"
fn modulePath(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    var parts = std.mem.splitScalar(u8, name, '_');
    var buf = std.ArrayList(u8).empty;
    var first = true;
    while (parts.next()) |part| {
        if (!first) try buf.append(alloc, '/');
        try buf.appendSlice(alloc, part);
        first = false;
    }
    if (buf.items.len == 0) return alloc.dupe(u8, "untitled");
    // Singularize the last segment: dict_datas → dict_data (but we keep original)
    return buf.toOwnedSlice(alloc);
}

/// Audit project for AI compliance: .gen.zig boundaries, ext/ structure, import correctness.
fn handleCheck(allocator: std.mem.Allocator) !void {
    std.debug.print("\n🔍 ZFinal AI Compliance Check\n", .{});
    std.debug.print("═══════════════════════════════\n\n", .{});

    var pass: u32 = 0;
    var warn: u32 = 0;
    var fail: u32 = 0;

    // 1. Check CLAUDE.md exists
    if (std.Io.Dir.cwd().access(io, "CLAUDE.md", .{})) |_| {
        std.debug.print("✅ PASS: CLAUDE.md exists\n", .{});
        pass += 1;
    } else |_| {
        std.debug.print("⚠️  WARN: No CLAUDE.md — AI may not know project rules. Run: zf new\n", .{});
        warn += 1;
    }

    // 2. Count .gen.zig files (they should not be hand-edited)
    var gen_count: u32 = 0;
    countGenFiles(allocator, &gen_count);
    if (gen_count > 0) {
        std.debug.print("✅ PASS: {d} .gen.zig files detected (auto-generated, do not edit)\n", .{gen_count});
        pass += 1;
    }

    // 3. Check ext/ directories exist for each module with .gen.zig
    var ext_ok: u32 = 0;
    var ext_miss: u32 = 0;
    checkExtDirs(allocator, &ext_ok, &ext_miss, &fail);
    if (ext_miss == 0 and ext_ok > 0) {
        std.debug.print("✅ PASS: all ext/ directories present ({d} modules)\n", .{ext_ok});
        pass += 1;
    }

    // 4. Detect .zig files outside ext/ that should be in ext/
    checkOrphanHandlers(allocator, &warn);

    std.debug.print("\n═══════════════════════════════\n", .{});
    std.debug.print("Results: {d} pass  {d} warn  {d} fail\n", .{ pass, warn, fail });
    if (fail > 0) {
        std.debug.print("\n❌ FAIL: Fix {d} issue(s) before committing.\n", .{fail});
    } else if (warn > 0) {
        std.debug.print("\n⚠️  PASS with {d} warning(s). Review before committing.\n", .{warn});
    } else {
        std.debug.print("\n✅ All checks passed. AI compliance verified.\n", .{});
    }
    std.debug.print("\n", .{});
}

fn countGenFiles(allocator: std.mem.Allocator, count: *u32) void {
    var modules_dir = std.Io.Dir.cwd().openDir(io, "src/modules", .{ .iterate = true }) catch {
        count.* = 0;
        return;
    };
    defer modules_dir.close(io);

    var walker = modules_dir.walk(allocator) catch return;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.basename, ".gen.zig")) count.* += 1;
    }
}

fn checkExtDirs(allocator: std.mem.Allocator, ok: *u32, miss: *u32, fail: *u32) void {
    var modules_dir = std.Io.Dir.cwd().openDir(io, "src/modules", .{ .iterate = true }) catch return;
    defer modules_dir.close(io);

    var walker = modules_dir.walk(allocator) catch return;
    defer walker.deinit();

    // Use simple array for dedup — fewer than 256 modules is safe
    var checked: [256][]const u8 = undefined;
    var checked_count: usize = 0;

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".gen.zig")) continue;

        const dir_path = std.fs.path.dirname(entry.path) orelse continue;

        // Check if we've already processed this directory
        var seen = false;
        for (checked[0..checked_count]) |c| {
            if (std.mem.eql(u8, c, dir_path)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        if (checked_count < checked.len) {
            checked[checked_count] = dir_path;
            checked_count += 1;
        }

        if (modules_dir.openDir(io, dir_path, .{})) |mod_dir| {
            defer mod_dir.close(io);
            if (mod_dir.openDir(io, "ext", .{})) |ext_dir| {
                ext_dir.close(io);
                ok.* += 1;
            } else |_| {
                std.debug.print("❌ FAIL: missing ext/ at src/modules/{s}/\n", .{dir_path});
                fail.* += 1;
                miss.* += 1;
            }
        } else |_| {}
    }
}

fn checkOrphanHandlers(allocator: std.mem.Allocator, warn: *u32) void {
    var handler_dir = std.Io.Dir.cwd().openDir(io, "src/handler", .{ .iterate = true }) catch return;
    defer handler_dir.close(io);

    var walker = handler_dir.walk(allocator) catch return;
    defer walker.deinit();

    var buf1: [256]u8 = undefined;
    var buf2: [512]u8 = undefined;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.endsWith(u8, entry.basename, ".gen.zig")) continue;
        if (std.mem.indexOf(u8, entry.path, "/ext/") != null) continue;

        const stem = entry.basename[0 .. entry.basename.len - 4];
        const gen_name = std.fmt.bufPrint(&buf1, "{s}.gen.zig", .{stem}) catch continue;
        const dir_name = std.fs.path.dirname(entry.path) orelse ".";
        const gen_path = std.fmt.bufPrint(&buf2, "{s}/{s}", .{ dir_name, gen_name }) catch continue;

        if (std.Io.Dir.cwd().access(io, gen_path, .{})) {
            std.debug.print("⚠️  WARN: {s} near .gen.zig — move to ext/{s}\n", .{ entry.path, entry.basename });
            warn.* += 1;
        } else |_| {}
    }
}

/// Upgrade zfinal dependency to the latest release (auto-executes zig fetch).
fn handleUpgrade(allocator: std.mem.Allocator) !void {
    const latest = zf_cfg.version;
    std.debug.print("\n⬆️  zf upgrade (target: {s})\n", .{latest});

    // Read current build.zig.zon
    const zon_file = std.Io.Dir.cwd().openFile(io, "build.zig.zon", .{}) catch {
        std.debug.print("   ⚠️  No build.zig.zon — not in a zfinal project?\n", .{});
        return;
    };
    defer zon_file.close(io);

    const stat = zon_file.stat(io) catch return;
    var zon_buf = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(zon_buf);
    _ = std.Io.File.readPositionalAll(zon_file, io, zon_buf, 0) catch {
        std.debug.print("   ❌ Failed to read build.zig.zon\n", .{});
        return;
    };

    var current_tag: []const u8 = "unknown";
    if (std.mem.indexOf(u8, zon_buf, "refs/tags/")) |tag_start| {
        const t = zon_buf[tag_start + "refs/tags/".len ..];
        if (std.mem.indexOf(u8, t, ".tar.gz")) |tag_end| {
            current_tag = t[0..tag_end];
        }
    }
    std.debug.print("   Project: {s}\n", .{current_tag});

    if (std.mem.eql(u8, current_tag, latest)) {
        std.debug.print("\n✅ Already at latest ({s}).\n", .{latest});
        return;
    }

    const url = try std.fmt.allocPrint(allocator, "https://github.com/chy3xyz/zfinal/archive/refs/tags/{s}.tar.gz", .{latest});
    defer allocator.free(url);

    std.debug.print("   Running: zig fetch --save {s}\n", .{url});
    const result = std.process.run(allocator, io, .{ .argv = &.{ "zig", "fetch", "--save", url } }) catch {
        std.debug.print("   ❌ Failed to run zig fetch. Run manually:\n   zig fetch --save {s}\n", .{url});
        return;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited == 0) {
        std.debug.print("\n✅ Upgraded {s} → {s}\n   Run: zig build\n\n", .{ current_tag, latest });
    } else {
        std.debug.print("   ❌ zig fetch failed:\n{s}\n", .{result.stderr});
    }
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

/// Generate AI tool configs: Claude Code, OpenCode, Cursor.
fn writeAiConfigs(allocator: std.mem.Allocator, cwd: std.Io.Dir) !void {
    // .claude/skills/
    try cwd.createDirPath(io, ".claude/skills");
    var claude_dir = try cwd.openDir(io, ".claude/skills", .{});
    defer claude_dir.close(io);
    try writeFile(claude_dir, "zfinal-app.md", templates.claude_skill);

    // .opencode/
    try cwd.createDirPath(io, ".opencode");
    var opencode_dir = try cwd.openDir(io, ".opencode", .{});
    defer opencode_dir.close(io);
    try writeFile(opencode_dir, "instructions.md", templates.opencode_instructions);

    // .cursor/rules/
    try cwd.createDirPath(io, ".cursor/rules");
    var cursor_dir = try cwd.openDir(io, ".cursor/rules", .{});
    defer cursor_dir.close(io);
    try writeFile(cursor_dir, "zfinal.mdc", templates.cursor_rules);

    _ = allocator;
}

pub fn hasFlag(args: [][]const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
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
        if (c == '_' or c == '-') {
            cap = true;
            continue;
        }
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

// ============================================================
// Safety guard — prevents overwriting user-modified code
// ============================================================

/// Write file safely: if file already exists, generate to .gen.new instead.
/// This prevents accidental overwrite of business logic added after initial generation.
/// User must manually review and merge the .gen.new file.
fn safeWrite(allocator: std.mem.Allocator, path: []const u8, data: []const u8, force: bool) !void {
    const exists = std.Io.Dir.cwd().access(io, path, .{}) != error.FileNotFound;
    if (!exists or force) {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
        const tag: []const u8 = if (force and exists) "Overwritten" else "Generated";
        std.debug.print("✅ {s}: {s}\n", .{ tag, path });
        return;
    }

    // File exists — write to .gen.new to avoid overwriting business logic
    const new_path = try std.fmt.allocPrint(allocator, "{s}.gen.new", .{path});
    defer allocator.free(new_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = new_path, .data = data });
    std.debug.print("⚠️  EXISTS: {s} — generated to {s}.gen.new\n", .{ path, path });
    std.debug.print("   Review with: diff {s} {s}.gen.new  then merge, or use --force\n", .{ path, path });
}
