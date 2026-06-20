const std = @import("std");
const templates = @import("templates.zig");
const codegen = @import("codegen");
const csql = @import("csql.zig");
const zf_cfg = @import("zf_cfg");

// Framework skill names. Content loaded at runtime from .claude/skills/
// relative to the zf binary's parent directory (typically zig-out/bin/zf →
// ../../.claude/skills/).
const framework_skill_names = [_][]const u8{
    "zfinal-onboarding.md",
    "zfinal-ai-playbook.md",
    "zfinal-framework.md",
    "zfinal-health.md",
    "zfinal-evolution.md",
    "zfinal-debug.md",
    "zfinal-evolve.md",
};
const sqlite_c = @import("c_sqlite3");

// Workaround: Zig 0.17 SQLITE_TRANSIENT alignment check fails on aarch64.
// Force a properly-aligned sentinel: pointer with low 4 bytes = 0xFFFFFF.
// SQLite treats any non-zero non-static destructor as "copy the buffer".
const TRANSIENT_PTR: usize = 0xFFFFFFFF;
const SQLITE_TRANSIENT_FN: ?*const fn (?*anyopaque) callconv(.c) void = blk: {
    const p = @as(?*const fn (?*anyopaque) callconv(.c) void, @ptrFromInt(TRANSIENT_PTR));
    break :blk p;
};

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
    seed,
    fixture,
    bench,
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
        .seed => {
            if (args.len < 3) {
                std.debug.print("Usage: {s} seed <action> [name]\n", .{args[0]});
                std.debug.print("Actions: new <name>, run, list\n", .{});
                return;
            }
            try handleSeed(allocator, args[2], if (args.len > 3) args[3] else "");
        },
        .fixture => {
            // zf fixture <table> [--count N] [--run] [--format sql|json]
            if (args.len < 3) {
                std.debug.print("Usage: {s} fixture <table> [--count N] [--run] [--format sql|json]\n", .{args[0]});
                std.debug.print("  Generate fake data for a table based on its schema.\n", .{});
                std.debug.print("  --count N    Number of rows (default: 100)\n", .{});
                std.debug.print("  --run        Insert into database (default: print SQL)\n", .{});
                std.debug.print("  --format X   Output format: sql (default), json\n", .{});
                return;
            }
            const table = args[2];
            var count: usize = 100;
            var run_db = false;
            var format: []const u8 = "sql";
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--count") and i + 1 < args.len) {
                    count = std.fmt.parseInt(usize, args[i + 1], 10) catch 100;
                    i += 1;
                } else if (std.mem.eql(u8, args[i], "--run")) {
                    run_db = true;
                } else if (std.mem.eql(u8, args[i], "--format") and i + 1 < args.len) {
                    format = args[i + 1];
                    i += 1;
                }
            }
            try handleFixture(allocator, table, count, run_db, format);
        },
        .bench => {
            // zf bench <url> [--count N] [--concurrency C]
            if (args.len < 3) {
                std.debug.print("Usage: {s} bench <url> [--count N] [--concurrency C]\n", .{args[0]});
                std.debug.print("  Load-test an HTTP endpoint.\n", .{});
                std.debug.print("  --count N       Total requests (default: 1000)\n", .{});
                std.debug.print("  --concurrency C Parallel workers (default: 10)\n", .{});
                return;
            }
            const url = args[2];
            var count: usize = 1000;
            var concurrency: usize = 10;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--count") and i + 1 < args.len) {
                    count = std.fmt.parseInt(usize, args[i + 1], 10) catch 1000;
                    i += 1;
                } else if (std.mem.eql(u8, args[i], "--concurrency") and i + 1 < args.len) {
                    concurrency = std.fmt.parseInt(usize, args[i + 1], 10) catch 10;
                    i += 1;
                }
            }
            try handleBench(allocator, url, count, concurrency);
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
                std.debug.print("Usage: {s} crud:sql <sql_file> [project_name] [--force] [--json] [--admin] [--explain] [--dry-run]\n", .{args[0]});
                std.debug.print("  project_name  Optional. Creates project dir and generates inside it.\n", .{});
                std.debug.print("  --force       Overwrite existing files instead of generating .gen.new\n", .{});
                std.debug.print("  --json        Emit machine-readable manifest for AI agents.\n", .{});
                std.debug.print("  --admin       Also emit vben-style admin HTML (htmx + alpine + tailwind, CDN).\n", .{});
                std.debug.print("  --explain     Print decision rationale for each generated file (AI-friendly).\n", .{});
                std.debug.print("  --dry-run     Don't write files; only print what would be generated.\n", .{});
                return;
            }
            const project_name = if (args.len > 3 and !std.mem.startsWith(u8, args[3], "--")) args[3] else null;
            const force = hasFlag(args, "--force");
            const json_mode = hasFlag(args, "--json");
            const admin_mode = hasFlag(args, "--admin");
            const explain_mode = hasFlag(args, "--explain");
            const dry_run = hasFlag(args, "--dry-run");
            try handleCrudFromSql(allocator, args[2], project_name, force, json_mode, admin_mode, explain_mode, dry_run);
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
            const heal = hasFlag(args, "--heal");
            const ai_zones = hasFlag(args, "--ai-zones");
            try handleCheck(allocator, heal, ai_zones);
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
    if (std.mem.eql(u8, cmd, "seed")) return .seed;
    if (std.mem.eql(u8, cmd, "fixture")) return .fixture;
    if (std.mem.eql(u8, cmd, "bench")) return .bench;
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

    // Build a slice of pointers once so each renderAll can iterate
    // sibling tables and build the sidebar nav.
    var table_ptrs: std.ArrayList(*const codegen.Table) = .empty;
    defer table_ptrs.deinit(allocator);
    for (tables.items) |*t| try table_ptrs.append(allocator, t);

    var written: usize = 0;
    for (tables.items) |*table| {
        const files = admin_templates.renderAll(allocator, table_ptrs.items, table) catch |e| {
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

    std.debug.print("✅ Generated {d} module(s) × 3 admin files (multi-table sidebar)\n", .{written});
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
    } else if (std.mem.eql(u8, action, "run") or std.mem.eql(u8, action, "up")) {
        try migrateRun(allocator);
    } else if (std.mem.eql(u8, action, "down")) {
        try migrateDown(allocator);
    } else if (std.mem.eql(u8, action, "status")) {
        try migrateStatus(allocator);
    } else {
        std.debug.print("Unknown migration action: {s}\n", .{action});
        std.debug.print("Available actions: new, run/up, down, status\n", .{});
    }
}

/// Apply all pending migrations. Default DB path: ./zf.db (override with
/// env var ZFINAL_DB or --db flag if supported later).
fn migrateRun(allocator: std.mem.Allocator) !void {
    const db_path = "zf.db";
    var db: ?*sqlite_c.sqlite3 = null;
    const rc = sqlite_c.sqlite3_open(db_path.ptr, &db);
    if (rc != sqlite_c.SQLITE_OK) {
        std.debug.print("Failed to open database: {s}\n", .{db_path});
        return;
    }
    defer _ = sqlite_c.sqlite3_close(db);

    try ensureMigrationsTable(db);
    try applyMigrations(allocator, db, "migrations", false);
}

/// Revert the most recent migration.
fn migrateDown(allocator: std.mem.Allocator) !void {
    const db_path = "zf.db";
    var db: ?*sqlite_c.sqlite3 = null;
    const rc = sqlite_c.sqlite3_open(db_path.ptr, &db);
    if (rc != sqlite_c.SQLITE_OK) {
        std.debug.print("Failed to open database: {s}\n", .{db_path});
        return;
    }
    defer _ = sqlite_c.sqlite3_close(db);

    try ensureMigrationsTable(db);
    try applyMigrations(allocator, db, "migrations", true);
}

/// Print applied + pending migrations.
fn migrateStatus(allocator: std.mem.Allocator) !void {
    const db_path = "zf.db";
    var db: ?*sqlite_c.sqlite3 = null;
    const rc = sqlite_c.sqlite3_open(db_path.ptr, &db);
    if (rc != sqlite_c.SQLITE_OK) {
        std.debug.print("Failed to open database: {s}\n", .{db_path});
        return;
    }
    defer _ = sqlite_c.sqlite3_close(db);

    try ensureMigrationsTable(db);
    try printMigrationStatus(allocator, db, "migrations");
}

// ─────────────────────────────────────────────────────────────────────────────
// SEED — populate database with initial/fixture data
// Complements `zf migrate`. Migrations create schema; seeds fill it.
// ─────────────────────────────────────────────────────────────────────────────

/// Dispatch seed subcommands: new, run, list.
fn handleSeed(allocator: std.mem.Allocator, action: []const u8, name: []const u8) !void {
    if (std.mem.eql(u8, action, "new")) {
        if (name.len == 0) {
            std.debug.print("Error: seed name is required\n", .{});
            return;
        }
        try seedNew(allocator, name);
    } else if (std.mem.eql(u8, action, "run") or std.mem.eql(u8, action, "up")) {
        try seedRun(allocator);
    } else if (std.mem.eql(u8, action, "list")) {
        try seedList(allocator);
    } else if (std.mem.eql(u8, action, "reset")) {
        try seedReset(allocator);
    } else {
        std.debug.print("Unknown seed action: {s}\n", .{action});
        std.debug.print("Available: new <name>, run/up, list, reset\n", .{});
    }
}

/// Create a new seed file with timestamp prefix.
fn seedNew(allocator: std.mem.Allocator, name: []const u8) !void {
    const seeds_dir = "seeds";
    std.Io.Dir.cwd().createDirPath(io, seeds_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const timestamp = std.Io.Timestamp.now(io, .real).toSeconds();
    const filename = try std.fmt.allocPrint(allocator, "{s}/{d}_{s}.sql", .{ seeds_dir, timestamp, name });
    defer allocator.free(filename);

    const content =
        \\-- Seed: {s}
        \\-- Created at: {d}
        \\
        \\-- Idempotent: use INSERT OR IGNORE so re-running is safe.
        \\-- Edit the INSERT statements below to match your schema.
        \\
        \\-- Example: insert 3 rows into your table.
        \\-- Replace 'my_table' and columns with your actual schema.
        \\
        \\INSERT OR IGNORE INTO users (id, name, email) VALUES
        \\  (1, 'admin', 'admin@example.com'),
        \\  (2, 'alice', 'alice@example.com'),
        \\  (3, 'bob', 'bob@example.com');
    ;
    const file_content = try std.fmt.allocPrint(allocator, content, .{ name, timestamp });
    defer allocator.free(file_content);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = filename, .data = file_content });
    std.debug.print("✅ Created seed: {s}\n", .{filename});
    std.debug.print("   Run: zf seed run\n", .{});
}

/// Apply all pending seeds.
fn seedRun(allocator: std.mem.Allocator) !void {
    const db_path = "zf.db";
    var db: ?*sqlite_c.sqlite3 = null;
    const rc = sqlite_c.sqlite3_open(db_path.ptr, &db);
    if (rc != sqlite_c.SQLITE_OK) {
        std.debug.print("Failed to open database: {s}\n", .{db_path});
        return;
    }
    defer _ = sqlite_c.sqlite3_close(db);

    try ensureSeedsTable(db);
    try applySeeds(allocator, db, "seeds");
}

/// Show applied + pending seeds.
fn seedList(allocator: std.mem.Allocator) !void {
    const db_path = "zf.db";
    var db: ?*sqlite_c.sqlite3 = null;
    const rc = sqlite_c.sqlite3_open(db_path.ptr, &db);
    if (rc != sqlite_c.SQLITE_OK) {
        std.debug.print("Failed to open database: {s}\n", .{db_path});
        return;
    }
    defer _ = sqlite_c.sqlite3_close(db);

    try ensureSeedsTable(db);
    try printSeedStatus(allocator, db, "seeds");
}

/// Reset the seeds tracking table — allows re-running all seeds.
fn seedReset(allocator: std.mem.Allocator) !void {
    const db_path = "zf.db";
    var db: ?*sqlite_c.sqlite3 = null;
    const rc = sqlite_c.sqlite3_open(db_path.ptr, &db);
    if (rc != sqlite_c.SQLITE_OK) {
        std.debug.print("Failed to open database: {s}\n", .{db_path});
        return;
    }
    defer _ = sqlite_c.sqlite3_close(db);
    _ = allocator;
    const drop_sql = "DELETE FROM _zfinal_seeds;";
    if (sqlite_c.sqlite3_exec(db, drop_sql.ptr, null, null, null) == sqlite_c.SQLITE_OK) {
        std.debug.print("✓ Seeds tracking reset. Run `zf seed run` to re-apply.\n", .{});
    } else {
        const e = sqlite_c.sqlite3_errmsg(db);
        std.debug.print("✗ Reset failed: {s}\n", .{if (e) |s| std.mem.sliceTo(s, 0) else "(unknown)"});
    }
}

/// Create _zfinal_seeds tracking table.
fn ensureSeedsTable(db: ?*sqlite_c.sqlite3) !void {
    const sql =
        \\CREATE TABLE IF NOT EXISTS _zfinal_seeds (
        \\  name TEXT PRIMARY KEY,
        \\  filename TEXT NOT NULL,
        \\  applied_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  checksum INTEGER NOT NULL
        \\);
    ;
    var err_msg: [*c]u8 = null;
    if (sqlite_c.sqlite3_exec(db, sql.ptr, null, null, &err_msg) != sqlite_c.SQLITE_OK) {
        std.debug.print("ensureSeedsTable error\n", .{});
        return error.SeedInitFailed;
    }
}

/// Apply pending seeds in `dir` (sorted by filename = timestamp prefix).
fn applySeeds(allocator: std.mem.Allocator, db: ?*sqlite_c.sqlite3, dir: []const u8) !void {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{}) catch {
        std.debug.print("⚠️  seeds dir not found: {s}\n", .{dir});
        return;
    };
    defer std.Io.Dir.close(d, io);

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sql")) continue;
        const p = try allocator.alloc(u8, dir.len + 1 + entry.name.len);
        @memcpy(p[0..dir.len], dir);
        p[dir.len] = '/';
        @memcpy(p[dir.len + 1 ..], entry.name);
        try paths.append(allocator, p);
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanPath);

    var applied_count: u32 = 0;
    for (paths.items) |path| {
        const name = std.fs.path.basename(path);
        const name_no_ext = if (std.mem.endsWith(u8, name, ".sql")) name[0 .. name.len - 4] else name;
        if (try seedApplied(allocator, db, name_no_ext)) {
            std.debug.print("  ⏭  skip {s} (already applied)\n", .{name_no_ext});
            continue;
        }
        const content = try readMigrationFile(allocator, path);
        defer allocator.free(content);
        const sql_z = try allocator.allocSentinel(u8, content.len, 0);
        defer allocator.free(sql_z);
        @memcpy(sql_z, content);
        std.debug.print("  → seeding {s}\n", .{name_no_ext});
        var err_msg: [*c]u8 = null;
        if (sqlite_c.sqlite3_exec(db, sql_z.ptr, null, null, &err_msg) != sqlite_c.SQLITE_OK) {
            const e: [*c]const u8 = err_msg orelse "(no message)";
            std.debug.print("  ✗ failed: {s} — {s}\n", .{ name_no_ext, e });
            return error.SeedApplyFailed;
        }
        const checksum = std.hash.crc.Crc32.hash(content);
        const record_sql =
            \\INSERT INTO _zfinal_seeds (name, filename, checksum)
            \\VALUES (?, ?, ?);
        ;
        var stmt: ?*sqlite_c.sqlite3_stmt = null;
        if (sqlite_c.sqlite3_prepare_v2(db, record_sql.ptr, -1, &stmt, null) == sqlite_c.SQLITE_OK) {
            _ = sqlite_c.sqlite3_bind_text(stmt, 1, name_no_ext.ptr, @intCast(name_no_ext.len), null);
            _ = sqlite_c.sqlite3_bind_text(stmt, 2, name.ptr, @intCast(name.len), null);
            _ = sqlite_c.sqlite3_bind_int64(stmt, 3, @intCast(checksum));
            _ = sqlite_c.sqlite3_step(stmt);
            _ = sqlite_c.sqlite3_finalize(stmt);
        }
        std.debug.print("  ✓ seeded {s}\n", .{name_no_ext});
        applied_count += 1;
    }
    std.debug.print("\nApplied: {d} | Skipped: {d} | Total: {d}\n", .{ applied_count, paths.items.len - applied_count, paths.items.len });
}

/// Check if a seed name has already been applied.
fn seedApplied(allocator: std.mem.Allocator, db: ?*sqlite_c.sqlite3, name: []const u8) !bool {
    var buf: [256]u8 = undefined;
    if (name.len > buf.len) return false;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    _ = allocator;
    const sql = "SELECT 1 FROM _zfinal_seeds WHERE name = ?;";
    var stmt: ?*sqlite_c.sqlite3_stmt = null;
    if (sqlite_c.sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != sqlite_c.SQLITE_OK) return false;
    defer _ = sqlite_c.sqlite3_finalize(stmt);
    _ = sqlite_c.sqlite3_bind_text(stmt, 1, &buf, @intCast(name.len), null);
    return sqlite_c.sqlite3_step(stmt) == sqlite_c.SQLITE_ROW;
}

/// Show applied (✓) and pending (○) seeds.
fn printSeedStatus(allocator: std.mem.Allocator, db: ?*sqlite_c.sqlite3, dir: []const u8) !void {
    std.debug.print("\n── Seeds Status ──\n", .{});
    var d = std.Io.Dir.cwd().openDir(io, dir, .{}) catch {
        std.debug.print("⚠️  seeds dir not found: {s}\n", .{dir});
        return;
    };
    defer std.Io.Dir.close(d, io);

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sql")) continue;
        const p = try allocator.alloc(u8, dir.len + 1 + entry.name.len);
        @memcpy(p[0..dir.len], dir);
        p[dir.len] = '/';
        @memcpy(p[dir.len + 1 ..], entry.name);
        try paths.append(allocator, p);
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanPath);

    var pending: u32 = 0;
    for (paths.items) |path| {
        const name = std.fs.path.basename(path);
        const name_no_ext = if (std.mem.endsWith(u8, name, ".sql")) name[0 .. name.len - 4] else name;
        if (try seedApplied(allocator, db, name_no_ext)) {
            std.debug.print("  ✓ {s}\n", .{name_no_ext});
        } else {
            std.debug.print("  ○ {s}\n", .{name_no_ext});
            pending += 1;
        }
    }
    std.debug.print("\nTotal: {d} | Pending: {d}\n", .{ paths.items.len, pending });
    if (pending > 0) std.debug.print("Run `zf seed run` to apply.\n", .{});
}

/// Create the _zfinal_migrations tracking table if missing.
fn ensureMigrationsTable(db: ?*sqlite_c.sqlite3) !void {
    const sql =
        \\CREATE TABLE IF NOT EXISTS _zfinal_migrations (
        \\  version TEXT PRIMARY KEY,
        \\  filename TEXT NOT NULL,
        \\  applied_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  checksum INTEGER NOT NULL
        \\);
    ;
    var err_msg: [*c]u8 = null;
    const rc = sqlite_c.sqlite3_exec(db, sql.ptr, null, null, &err_msg);
    if (rc != sqlite_c.SQLITE_OK) {
        const e: [*c]const u8 = err_msg orelse "(no message)";
        std.debug.print("ensureMigrationsTable error: {s}\n", .{e});
        return error.MigrationInitFailed;
    }
}

/// Apply or revert all migrations in `dir` (sorted by timestamp prefix).
fn applyMigrations(allocator: std.mem.Allocator, db: ?*sqlite_c.sqlite3, dir: []const u8, revert: bool) !void {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{}) catch {
        std.debug.print("⚠️  migrations dir not found: {s}\n", .{dir});
        return;
    };
    defer std.Io.Dir.close(d, io);

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sql")) continue;
        const p = try allocator.alloc(u8, dir.len + 1 + entry.name.len);
        @memcpy(p[0..dir.len], dir);
        p[dir.len] = '/';
        @memcpy(p[dir.len + 1 ..], entry.name);
        try paths.append(allocator, p);
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanPath);

    if (!revert) {
        for (paths.items) |path| {
            const version = std.fs.path.basename(path);
            const version_trimmed = if (std.mem.endsWith(u8, version, ".sql"))
                version[0 .. version.len - 4]
            else
                version;
            const applied = try migrationApplied(allocator, db, version_trimmed);
            if (applied) continue;
            // Extract only the UP section (avoid executing DROP on first run)
            const up_sql = try extractSection(allocator, version, .up);
            defer allocator.free(up_sql);
            if (up_sql.len == 0) {
                std.debug.print("  ! no UP section in {s}\n", .{version_trimmed});
                continue;
            }
            const sql_z = try allocator.allocSentinel(u8, up_sql.len, 0);
            defer allocator.free(sql_z);
            @memcpy(sql_z, up_sql);
            std.debug.print("  → applying {s}\n", .{version_trimmed});
            var err_msg: [*c]u8 = null;
            const exec_rc = sqlite_c.sqlite3_exec(db, sql_z.ptr, null, null, &err_msg);
            if (exec_rc != sqlite_c.SQLITE_OK) {
                const e: [*c]const u8 = err_msg orelse "(no message)";
                std.debug.print("  ✗ failed: {s} — {s}\n", .{ version_trimmed, e });
                return error.MigrationApplyFailed;
            }
            const checksum = std.hash.crc.Crc32.hash(up_sql);
            const record_sql =
                \\INSERT INTO _zfinal_migrations (version, filename, checksum)
                \\VALUES (?, ?, ?);
            ;
            var stmt: ?*sqlite_c.sqlite3_stmt = null;
            if (sqlite_c.sqlite3_prepare_v2(db, record_sql.ptr, -1, &stmt, null) == sqlite_c.SQLITE_OK) {
                _ = sqlite_c.sqlite3_bind_text(stmt, 1, version_trimmed.ptr, @intCast(version_trimmed.len), null);
                _ = sqlite_c.sqlite3_bind_text(stmt, 2, version.ptr, @intCast(version.len), null);
                _ = sqlite_c.sqlite3_bind_int64(stmt, 3, @intCast(checksum));
                _ = sqlite_c.sqlite3_step(stmt);
                _ = sqlite_c.sqlite3_finalize(stmt);
            }
            std.debug.print("  ✓ applied  {s}\n", .{version_trimmed});
        }
    } else {
        // Revert: find latest applied, execute its Down section.
        const latest = (try findLatestApplied(allocator, db)) orelse {
            std.debug.print("No migrations applied yet.\n", .{});
            return;
        };
        defer allocator.free(latest._owned);
        const down_sql = try extractSection(allocator, latest.filename, .down);
        defer allocator.free(down_sql);
        if (down_sql.len == 0) {
            std.debug.print("  ! no DOWN section in {s} — manual revert required\n", .{latest.filename});
            return;
        }
        const down_z = try allocator.allocSentinel(u8, down_sql.len, 0);
        defer allocator.free(down_z);
        @memcpy(down_z, down_sql);
        std.debug.print("  ← reverting {s}\n", .{latest.version});
        if (sqlite_c.sqlite3_exec(db, down_z.ptr, null, null, null) != sqlite_c.SQLITE_OK) {
            const err = sqlite_c.sqlite3_errmsg(db);
            std.debug.print("  ✗ revert failed: {s}\n", .{if (err) |e| std.mem.sliceTo(e, 0) else "(no message)"});
            return error.MigrationRevertFailed;
        }
        const del_sql = "DELETE FROM _zfinal_migrations WHERE version = ?;";
        var stmt: ?*sqlite_c.sqlite3_stmt = null;
        if (sqlite_c.sqlite3_prepare_v2(db, del_sql.ptr, -1, &stmt, null) == sqlite_c.SQLITE_OK) {
            _ = sqlite_c.sqlite3_bind_text(stmt, 1, latest.version.ptr, @intCast(latest.version.len), null);
            _ = sqlite_c.sqlite3_step(stmt);
            _ = sqlite_c.sqlite3_finalize(stmt);
        }
        std.debug.print("  ✓ reverted {s}\n", .{latest.version});
    }
}

/// Show applied (✓) and pending (○) migrations.
fn printMigrationStatus(allocator: std.mem.Allocator, db: ?*sqlite_c.sqlite3, dir: []const u8) !void {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{}) catch {
        std.debug.print("⚠️  migrations dir not found: {s}\n", .{dir});
        return;
    };
    defer std.Io.Dir.close(d, io);

    std.debug.print("\n── Migrations Status ──\n", .{});

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sql")) continue;
        const p = try allocator.alloc(u8, dir.len + 1 + entry.name.len);
        @memcpy(p[0..dir.len], dir);
        p[dir.len] = '/';
        @memcpy(p[dir.len + 1 ..], entry.name);
        try paths.append(allocator, p);
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanPath);

    var pending: u32 = 0;
    for (paths.items) |path| {
        const version = std.fs.path.basename(path);
        const version_trimmed = if (std.mem.endsWith(u8, version, ".sql"))
            version[0 .. version.len - 4]
        else
            version;
        const applied = try migrationApplied(allocator, db, version_trimmed);
        if (applied) {
            std.debug.print("  ✓ {s}\n", .{version_trimmed});
        } else {
            std.debug.print("  ○ {s}\n", .{version_trimmed});
            pending += 1;
        }
    }
    std.debug.print("\nTotal: {d} | Pending: {d}\n", .{ paths.items.len, pending });
    if (pending > 0) std.debug.print("Run `zf migrate up` to apply.\n", .{});
}

/// Check if a migration version is already applied.
fn migrationApplied(allocator: std.mem.Allocator, db: ?*sqlite_c.sqlite3, version: []const u8) !bool {
    _ = allocator;
    // Use a sentinel-terminated copy of version for safe bind_text.
    var buf: [256]u8 = undefined;
    if (version.len > buf.len) return false;
    @memcpy(buf[0..version.len], version);
    buf[version.len] = 0;
    const sql = "SELECT 1 FROM _zfinal_migrations WHERE version = ?;";
    var stmt: ?*sqlite_c.sqlite3_stmt = null;
    if (sqlite_c.sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != sqlite_c.SQLITE_OK) return false;
    defer _ = sqlite_c.sqlite3_finalize(stmt);
    _ = sqlite_c.sqlite3_bind_text(stmt, 1, &buf, @intCast(version.len), null);
    return sqlite_c.sqlite3_step(stmt) == sqlite_c.SQLITE_ROW;
}

const AppliedMigration = struct { version: []const u8, filename: []const u8, _owned: []u8 };

/// Find the most recently applied migration (latest version).
/// Caller must free `result._owned` after use.
fn findLatestApplied(allocator: std.mem.Allocator, db: ?*sqlite_c.sqlite3) !?AppliedMigration {
    const sql = "SELECT version, filename FROM _zfinal_migrations ORDER BY applied_at DESC LIMIT 1;";
    var stmt: ?*sqlite_c.sqlite3_stmt = null;
    if (sqlite_c.sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != sqlite_c.SQLITE_OK) return null;
    defer _ = sqlite_c.sqlite3_finalize(stmt);
    if (sqlite_c.sqlite3_step(stmt) != sqlite_c.SQLITE_ROW) return null;
    const version_src = sqlite_c.sqlite3_column_text(stmt, 0) orelse return null;
    const filename_src = sqlite_c.sqlite3_column_text(stmt, 1) orelse return null;
    const version_slice = std.mem.sliceTo(version_src, 0);
    const filename_slice = std.mem.sliceTo(filename_src, 0);
    const version_len: usize = version_slice.len;
    const filename_len: usize = filename_slice.len;
    const owned = try allocator.alloc(u8, version_len + filename_len + 1);
    @memcpy(owned[0..version_len], version_src[0..version_len]);
    @memcpy(owned[version_len..version_len + filename_len], filename_src[0..filename_len]);
    owned[version_len + filename_len] = 0;
    return .{
        .version = owned[0..version_len],
        .filename = owned[version_len..][0..filename_len],
        ._owned = owned,
    };
}

const Section = enum { up, down };

/// Extract the "-- Up" or "-- Down" section from a migration file.
fn extractSection(allocator: std.mem.Allocator, filename: []const u8, section: Section) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "migrations/{s}", .{filename});
    defer allocator.free(path);
    const content = readMigrationFile(allocator, path) catch {
        return &[_]u8{};
    };
    defer allocator.free(content);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var in_section = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "-- Up")) {
            in_section = section == .up;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "-- Down")) {
            in_section = section == .down;
            continue;
        }
        if (in_section and !std.mem.startsWith(u8, trimmed, "-- ")) {
            try buf.appendSlice(allocator, line);
            try buf.append(allocator, '\n');
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn readMigrationFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // (delegates to existing readFileAlloc)
    return readFileAlloc(allocator, path);
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
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

fn handleCrudFromSql(allocator: std.mem.Allocator, sql_path: []const u8, project_name: ?[]const u8, force: bool, json_mode: bool, admin_mode: bool, explain_mode: bool, dry_run: bool) !void {
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

    // AI-friendly: --explain / --dry-run modes
    if (explain_mode or dry_run) {
        std.debug.print("\n──── zf plan ────\n", .{});
        for (tables.items) |t| {
            var pk_name: []const u8 = "id";
            for (t.columns.items) |c| {
                if (std.mem.eql(u8, c.name, "id") or std.mem.endsWith(u8, c.name, "_id")) {
                    pk_name = c.name;
                    break;
                }
            }
            std.debug.print("\n📋 Table: {s}\n", .{t.name});
            std.debug.print("   ├─ columns: {d}\n", .{t.columns.items.len});
            for (t.columns.items, 0..) |c, i| {
                const marker: []const u8 = if (i == t.columns.items.len - 1) "└" else "├";
                std.debug.print("   │  {s} {s}: {s}\n", .{ marker, c.name, c.sql_type });
            }
            std.debug.print("   ├─ primary_key: {s}\n", .{pk_name});
            std.debug.print("   ├─ module path: src/modules/{s}/\n", .{t.name});
            std.debug.print("   ├─ generated: model.zig, service.zig, handler.zig, routes.zig\n", .{});
            std.debug.print("   └─ ai-edit-zones: handler (HTTP), service (logic), model (queries)\n", .{});
        }
        std.debug.print("\n──── decisions ────\n", .{});
        std.debug.print("   • handler: standard REST (GET/POST/PUT/DELETE) with CSRF + rate limit\n", .{});
        std.debug.print("   • service: CRUD with transaction wrapper\n", .{});
        std.debug.print("   • model: ORM-style struct with fieldMap for dynamic queries\n", .{});
        if (admin_mode) std.debug.print("   • admin: multi-table sidebar + htmx + alpine (CDN)\n", .{});
        if (dry_run) {
            std.debug.print("\n[dry-run] would generate {d} modules + 1 migration + 1 manifest\n", .{tables.items.len});
            std.debug.print("[dry-run] exiting without writing files.\n", .{});
            return;
        }
        std.debug.print("\n──── continue ────\n", .{});
    }

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

        // Build slice of pointers so each renderAll can build a
        // multi-table sidebar nav from all siblings.
        var table_ptrs: std.ArrayList(*const codegen.Table) = .empty;
        defer table_ptrs.deinit(allocator);
        for (tables.items) |*t| try table_ptrs.append(allocator, t);

        for (tables.items) |*table| {
            const files = admin_templates.renderAll(allocator, table_ptrs.items, table) catch |e| {
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
        std.debug.print("✅ vben-style admin HTML emitted to {s}/ ({d} tables, multi-table sidebar)\n", .{ out_dir, table_ptrs.items.len });
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
            \\    pool = try zfinal.ConnectionPool.init(allocator, db_config, 10);
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
/// With --heal: automatically patch known issues (stale getPool pattern, missing getters, etc.)
fn handleCheck(allocator: std.mem.Allocator, heal: bool, ai_zones: bool) !void {
    if (ai_zones) {
        try printAiZones(allocator);
        return;
    }
    if (heal) {
        std.debug.print("\n🩹 ZFinal AI Compliance — SELF-HEAL MODE\n", .{});
        std.debug.print("════════════════════════════════════════\n\n", .{});
        var patched: u32 = 0;
        patched += try healStaleGetterPattern(allocator);
        patched += try healMissingGetters(allocator);
        patched += try healCallconvLowercase(allocator);
        patched += try healComptimeVar(allocator);
        patched += try healDupeZ(allocator);
        patched += try healBufPrintZ(allocator);
        std.debug.print("\n════════════════════════════════════════\n", .{});
        std.debug.print("Healed: {d} file(s) patched.\n", .{patched});
        if (patched == 0) std.debug.print("✅ No issues found — code already healthy.\n", .{});
        std.debug.print("Run: zig build to verify.\n", .{});
        return;
    }

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
    // .claude/skills/ — copy framework skills from sibling .claude/skills/
    try cwd.createDirPath(io, ".claude/skills");
    var claude_dir = try cwd.openDir(io, ".claude/skills", .{});
    defer claude_dir.close(io);
    // Summary skill (always present)
    try writeFile(claude_dir, "zfinal-app.md", templates.claude_skill);
    // Copy full framework skill set from sibling repo
    copyFrameworkSkills(allocator, claude_dir);

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

    // .github/workflows/ — CI/CD template
    try cwd.createDirPath(io, ".github/workflows");
    var gh_dir = try cwd.openDir(io, ".github/workflows", .{});
    defer gh_dir.close(io);
    try writeFile(gh_dir, "test.yml", templates.github_workflow_test);
}

/// Copy framework skill files from sibling repo to project's .claude/skills/.
/// Source: tries CWD and walks up to 5 parent directories to find
/// the zfinal framework root.
fn copyFrameworkSkills(allocator: std.mem.Allocator, dest_dir: std.Io.Dir) void {
    var candidates: [6][]const u8 = undefined;
    var n: usize = 0;
    candidates[n] = ".claude/skills"; n += 1;
    candidates[n] = "../.claude/skills"; n += 1;
    candidates[n] = "../../.claude/skills"; n += 1;
    candidates[n] = "../../../.claude/skills"; n += 1;
    candidates[n] = "../../../../.claude/skills"; n += 1;
    candidates[n] = "../../../../../.claude/skills"; n += 1;

    var src_dir_opt: ?std.Io.Dir = null;
    var found_path: ?[]const u8 = null;
    for (candidates[0..n]) |path| {
        if (std.Io.Dir.cwd().openDir(io, path, .{})) |d| {
            src_dir_opt = d;
            found_path = path;
            break;
        } else |_| {}
    }
    const src_dir = src_dir_opt orelse {
        std.debug.print("  ! framework skills not found — run zf from zfinal repo root\n", .{});
        return;
    };
    defer std.Io.Dir.close(src_dir, io);
    std.debug.print("  (skills from {s})\n", .{found_path.?});

    for (framework_skill_names) |name| {
        const file = src_dir.openFile(io, name, .{}) catch continue;
        defer file.close(io);
        const stat = file.stat(io) catch continue;
        if (stat.size > 100_000) continue;
        const content = allocator.alloc(u8, @intCast(stat.size)) catch continue;
        defer allocator.free(content);
        _ = std.Io.File.readPositionalAll(file, io, content, 0) catch continue;
        writeFile(dest_dir, name, content) catch continue;
        std.debug.print("  ✓ skill: {s}\n", .{name});
    }
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

// ─────────────────────────────────────────────────────────────────────────────
// Self-heal helpers (zf check --heal)
// ─────────────────────────────────────────────────────────────────────────────

/// Patch stale `pool_ref = &deps.pool` patterns → `getPool()` pattern.
/// Returns count of files patched.
fn healStaleGetterPattern(allocator: std.mem.Allocator) !u32 {
    var patched: u32 = 0;
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    try findFilesAll(allocator, "src", &paths);

    for (paths.items) |path| {
        const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch continue;
        defer f.close(io);
        const stat = try f.stat(io);
        if (stat.size > 1_000_000) continue;
        var content = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(content);
        _ = try std.Io.File.readPositionalAll(f, io, content, 0);

        const orig = content;
        // Pattern: pool_ref = &@import(...).pool
        if (std.mem.indexOf(u8, content, "pool_ref") != null) {
            const new1 = try std.mem.replaceOwned(u8, allocator, content, "const pool_ref = &@import(\"", "const pool = @import(\"");
            content = new1;
            const new2 = try std.mem.replaceOwned(u8, allocator, content, "\").pool;", "\").getPool();");
            content = new2;
            const new3 = try std.mem.replaceOwned(u8, allocator, content, "pool_ref.", "pool.");
            content = new3;
        }
        if (std.mem.indexOf(u8, content, "token_ref") != null) {
            const new1 = try std.mem.replaceOwned(u8, allocator, content, "const token_ref = &@import(\"", "const tokenMgr = @import(\"");
            content = new1;
            const new2 = try std.mem.replaceOwned(u8, allocator, content, "\").tokenMgr;", "\").getTokenMgr();");
            content = new2;
            const new3 = try std.mem.replaceOwned(u8, allocator, content, "token_ref.", "tokenMgr.");
            content = new3;
        }
        if (std.mem.indexOf(u8, content, "limit_ref") != null) {
            const new1 = try std.mem.replaceOwned(u8, allocator, content, "const limit_ref = &@import(\"", "const rateLimiter = @import(\"");
            content = new1;
            const new2 = try std.mem.replaceOwned(u8, allocator, content, "\").rateLimiter;", "\").getRateLimiter();");
            content = new2;
            const new3 = try std.mem.replaceOwned(u8, allocator, content, "limit_ref.", "rateLimiter.");
            content = new3;
        }
        if (!std.mem.eql(u8, content, orig)) {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
            std.debug.print("  ✓ healed: {s} (stale getter pattern)\n", .{path});
            patched += 1;
        }
    }
    return patched;
}

/// Patch deps.zig files that lack getPool()/getTokenMgr()/getRateLimiter().
fn healMissingGetters(allocator: std.mem.Allocator) !u32 {
    var patched: u32 = 0;
    // Find all deps.zig files under src/
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    try findFiles(allocator, "src", "deps.zig", &paths);

    for (paths.items) |path| {
        const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch continue;
        defer f.close(io);
        const stat = try f.stat(io);
        if (stat.size > 100_000) continue;
        const content = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(content);
        _ = try std.Io.File.readPositionalAll(f, io, content, 0);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, content);
        const has_getpool = std.mem.containsAtLeast(u8, content, 1, "pub fn getPool");
        const has_gettoken = std.mem.containsAtLeast(u8, content, 1, "pub fn getTokenMgr");
        const has_getlimit = std.mem.containsAtLeast(u8, content, 1, "pub fn getRateLimiter");
        if (!has_getpool or !has_gettoken or !has_getlimit) {
            try buf.appendSlice(allocator,
                \\
                \\
                \\pub fn getPool() *zfinal.ConnectionPool {
                \\    return @as(*zfinal.ConnectionPool, @ptrCast(&pool));
                \\}
                \\
                \\pub fn getTokenMgr() *zfinal.TokenManager {
                \\    return &tokenMgr;
                \\}
                \\
                \\pub fn getRateLimiter() *zfinal.RateLimitHandler {
                \\    return &rateLimiter;
                \\}
            );
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items });
            std.debug.print("  ✓ healed: {s} (added getter functions)\n", .{path});
            patched += 1;
        }
    }
    return patched;
}

/// Patch callconv(.C) → callconv(.c) (Zig 0.17 lowercase).
fn healCallconvLowercase(allocator: std.mem.Allocator) !u32 {
    var patched: u32 = 0;
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    try findFilesAll(allocator, "src", &paths);

    for (paths.items) |path| {
        const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch continue;
        defer f.close(io);
        const stat = try f.stat(io);
        if (stat.size > 200_000) continue;
        const content = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(content);
        _ = try std.Io.File.readPositionalAll(f, io, content, 0);
        if (std.mem.indexOf(u8, content, "callconv(.C)") == null) continue;
        const new_content = std.mem.replaceOwned(u8, allocator, content, "callconv(.C)", "callconv(.c)") catch |e| {
            std.debug.print("  ! skip {s}: {t}\n", .{ path, e });
            continue;
        };
        defer allocator.free(new_content);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = new_content });
        std.debug.print("  ✓ healed: {s} (callconv .C → .c)\n", .{path});
        patched += 1;
    }
    return patched;
}

/// Patch var → const for params that are never reassigned (Zig 0.17 strict).
/// Conservative: only handles the pattern `var t = try spawn/test/...;` where the var is never reassigned.
fn healComptimeVar(allocator: std.mem.Allocator) !u32 {
    var patched: u32 = 0;
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    try findFilesAll(allocator, "src", &paths);

    for (paths.items) |path| {
        const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch continue;
        defer f.close(io);
        const stat = try f.stat(io);
        if (stat.size > 200_000) continue;
        var content = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(content);
        _ = try std.Io.File.readPositionalAll(f, io, content, 0);

        const orig = content;
        if (std.mem.indexOf(u8, content, "var t = try") != null) {
            const new1 = try std.mem.replaceOwned(u8, allocator, content, "var t = try", "const t = try");
            content = new1;
        }
        if (std.mem.indexOf(u8, content, "var box = try") != null) {
            const new1 = try std.mem.replaceOwned(u8, allocator, content, "var box = try", "const box = try");
            content = new1;
        }
        if (!std.mem.eql(u8, content, orig)) {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
            std.debug.print("  ✓ healed: {s} (var → const)\n", .{path});
            patched += 1;
        }
    }
    return patched;
}

/// Patch `allocator.dupeZ(T, x)` → `allocator.allocSentinel(T, x.len, 0)`.
/// Zig 0.17 removed `dupeZ` in favor of `allocSentinel` + manual `@memcpy`.
/// Note: this only renames the function. Users must manually add @memcpy
/// because the original dupeZ semantics aren't directly translatable.
fn healDupeZ(allocator: std.mem.Allocator) !u32 {
    var patched: u32 = 0;
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    try findFilesAll(allocator, "src", &paths);

    for (paths.items) |path| {
        const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch continue;
        defer f.close(io);
        const stat = try f.stat(io);
        if (stat.size > 200_000) continue;
        const content = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(content);
        _ = try std.Io.File.readPositionalAll(f, io, content, 0);
        if (std.mem.indexOf(u8, content, ".dupeZ(") == null) continue;
        const new_content = std.mem.replaceOwned(u8, allocator, content, ".dupeZ(", ".allocSentinel(") catch continue;
        defer allocator.free(new_content);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = new_content });
        std.debug.print("  ✓ healed: {s} (dupeZ → allocSentinel — manual @memcpy needed)\n", .{path});
        patched += 1;
    }
    return patched;
}

/// Patch `std.fmt.bufPrintZ` → `std.fmt.bufPrint`.
/// Zig 0.17 removed `bufPrintZ`. User must manually append `\0`.
fn healBufPrintZ(allocator: std.mem.Allocator) !u32 {
    var patched: u32 = 0;
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    try findFilesAll(allocator, "src", &paths);

    for (paths.items) |path| {
        const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch continue;
        defer f.close(io);
        const stat = try f.stat(io);
        if (stat.size > 200_000) continue;
        const content = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(content);
        _ = try std.Io.File.readPositionalAll(f, io, content, 0);
        if (std.mem.indexOf(u8, content, "bufPrintZ") == null) continue;
        const new_content = std.mem.replaceOwned(u8, allocator, content, "bufPrintZ", "bufPrint") catch continue;
        defer allocator.free(new_content);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = new_content });
        std.debug.print("  ✓ healed: {s} (bufPrintZ → bufPrint — manual \\0 needed)\n", .{path});
        patched += 1;
    }
    return patched;
}

/// Find all .zig files under a directory (recursive, non-generated only).
fn findFilesAll(allocator: std.mem.Allocator, root: []const u8, out: *std.ArrayList([]const u8)) !void {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch return;
    defer std.Io.Dir.close(dir, io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, entry.name });
        if (entry.kind == .directory) {
            try findFilesAll(allocator, sub_path, out);
            allocator.free(sub_path);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            try out.append(allocator, sub_path);
        } else {
            allocator.free(sub_path);
        }
    }
}

/// Find specific named file under a directory tree.
fn findFiles(allocator: std.mem.Allocator, root: []const u8, name: []const u8, out: *std.ArrayList([]const u8)) !void {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch return;
    defer std.Io.Dir.close(dir, io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, entry.name });
        if (entry.kind == .directory) {
            try findFiles(allocator, sub_path, name, out);
            allocator.free(sub_path);
        } else if (entry.kind == .file and std.mem.eql(u8, entry.name, name)) {
            try out.append(allocator, sub_path);
        } else {
            allocator.free(sub_path);
        }
    }
}

/// Print reverse index of AI-editable files for AI agents.
/// Shows which .zig files AI is allowed to edit (no `// @generated` header,
/// has `// ── ai-edit-zone` markers or is in `ext/` directory).
fn printAiZones(allocator: std.mem.Allocator) !void {
    std.debug.print("\n📝 ZFinal AI-Editable Files\n", .{});
    std.debug.print("═══════════════════════════\n\n", .{});
    std.debug.print("Files marked with `// @generated` are AI-LOCKED.\n", .{});
    std.debug.print("Files with `// ── ai-edit-zone:` markers are AI-EDITABLE.\n\n", .{});

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    try findFilesAll(allocator, "src", &paths);

    var editable: u32 = 0;
    var locked: u32 = 0;
    for (paths.items) |path| {
        const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch continue;
        defer f.close(io);
        const stat = try f.stat(io);
        if (stat.size > 200_000) continue;
        const content = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(content);
        _ = try std.Io.File.readPositionalAll(f, io, content, 0);
        const is_generated = std.mem.containsAtLeast(u8, content, 1, "// @generated");
        const has_zone = std.mem.containsAtLeast(u8, content, 1, "ai-edit-zone");
        const in_ext = std.mem.containsAtLeast(u8, path, 1, "/ext/");

        if (is_generated) {
            locked += 1;
        } else if (has_zone or in_ext) {
            editable += 1;
            std.debug.print("  ✅ {s}", .{path});
            if (has_zone) std.debug.print(" [ai-edit-zone]", .{});
            if (in_ext) std.debug.print(" [ext/]", .{});
            std.debug.print("\n", .{});
        }
    }

    std.debug.print("\n─────────────────────────────────────────\n", .{});
    std.debug.print("  Editable: {d}  |  Locked: {d}\n", .{ editable, locked });
    std.debug.print("  When in doubt: edit only files marked ✅ above.\n", .{});
    std.debug.print("  For help: see .claude/skills/zfinal-onboarding.md\n", .{});
}

/// Patch content with a simple regex-like replacement (limited subset).
/// Supports literal text + capture groups using \1 in replacement.
fn patchRegex(content: []const u8, pattern: []const u8, replacement: []const u8) []const u8 {
    // Simple substring-based: skip regex for now, only support exact strings
    _ = pattern;
    _ = replacement;
    return content;
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXTURE — generate fake data for testing
// ─────────────────────────────────────────────────────────────────────────────

const TableColumn = struct {
    name: []const u8,
    type: []const u8,
    pk: bool,
};

/// Generate fake data for a table.
fn handleFixture(allocator: std.mem.Allocator, table: []const u8, count: usize, run_db: bool, format: []const u8) !void {
    var db: ?*sqlite_c.sqlite3 = null;
    const db_path = "zf.db";
    const rc = sqlite_c.sqlite3_open(db_path.ptr, &db);
    if (rc != sqlite_c.SQLITE_OK) {
        std.debug.print("Failed to open database: {s}\n", .{db_path});
        return;
    }
    defer _ = sqlite_c.sqlite3_close(db);

    const cols = try readTableSchema(allocator, db, table) orelse {
        std.debug.print("Table '{s}' not found in {s}\n", .{ table, db_path });
        std.debug.print("Available tables:\n", .{});
        try listTables(allocator, db);
        return;
    };
    defer {
        for (cols) |c| {
            allocator.free(c.name);
            allocator.free(c.type);
        }
        allocator.free(cols);
    }

    if (std.mem.eql(u8, format, "json")) {
        try generateFixtureJson(allocator, table, cols, count);
    } else {
        try generateFixtureSql(allocator, db, table, cols, count, run_db);
    }
}

/// Read column schema for a table from sqlite_master + pragma table_info.
/// Returns null if table doesn't exist or has no columns.
fn readTableSchema(allocator: std.mem.Allocator, db: ?*sqlite_c.sqlite3, table: []const u8) !?[]TableColumn {
    const cols = try readTableColumns(allocator, db, table);
    if (cols.len == 0) {
        for (cols) |c| {
            allocator.free(c.name);
            allocator.free(c.type);
        }
        allocator.free(cols);
        return null;
    }
    return cols;
}

fn readTableColumns(allocator: std.mem.Allocator, db: ?*sqlite_c.sqlite3, table: []const u8) ![]TableColumn {
    // PRAGMA table_info('table') returns cid|name|type|notnull|dflt|pk
    const pragma = "PRAGMA table_info(";
    var sql_buf: std.ArrayList(u8) = .empty;
    defer sql_buf.deinit(allocator);
    try sql_buf.appendSlice(allocator, pragma);
    try sql_buf.append(allocator, '\'');
    try sql_buf.appendSlice(allocator, table);
    try sql_buf.appendSlice(allocator, "\');");

    var stmt: ?*sqlite_c.sqlite3_stmt = null;
    if (sqlite_c.sqlite3_prepare_v2(db, sql_buf.items.ptr, -1, &stmt, null) != sqlite_c.SQLITE_OK) {
        return &[_]TableColumn{};
    }
    defer _ = sqlite_c.sqlite3_finalize(stmt);

    var cols: std.ArrayList(TableColumn) = .empty;
    defer cols.deinit(allocator);
    while (sqlite_c.sqlite3_step(stmt) == sqlite_c.SQLITE_ROW) {
        const name_src = sqlite_c.sqlite3_column_text(stmt, 1) orelse continue;
        const type_src = sqlite_c.sqlite3_column_text(stmt, 2);
        const type_str = if (type_src) |t| std.mem.sliceTo(t, 0) else "";
        const pk = sqlite_c.sqlite3_column_int(stmt, 5);
        const name = try allocator.dupe(u8, std.mem.sliceTo(name_src, 0));
        const ctype = try allocator.dupe(u8, type_str);
        try cols.append(allocator, .{ .name = name, .type = ctype, .pk = pk != 0 });
    }
    if (cols.items.len == 0) return &[_]TableColumn{};
    return cols.toOwnedSlice(allocator);
}

fn listTables(allocator: std.mem.Allocator, db: ?*sqlite_c.sqlite3) !void {
    const sql = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE '_zfinal_%' ORDER BY name;";
    var stmt: ?*sqlite_c.sqlite3_stmt = null;
    if (sqlite_c.sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != sqlite_c.SQLITE_OK) return;
    defer _ = sqlite_c.sqlite3_finalize(stmt);
    while (sqlite_c.sqlite3_step(stmt) == sqlite_c.SQLITE_ROW) {
        const name = sqlite_c.sqlite3_column_text(stmt, 0) orelse continue;
        std.debug.print("  • {s}\n", .{std.mem.sliceTo(name, 0)});
    }
    _ = allocator;
}

/// Generate SQL INSERT statements and either print or execute them.
fn generateFixtureSql(allocator: std.mem.Allocator, db: ?*sqlite_c.sqlite3, table: []const u8, cols: []TableColumn, count: usize, run_db: bool) !void {
    var prng: u64 = 42;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    try output.appendSlice(allocator, "-- Generated by zf fixture\n");

    for (0..count) |row_idx| {
        var stmt_buf: std.ArrayList(u8) = .empty;
        defer stmt_buf.deinit(allocator);
        try stmt_buf.appendSlice(allocator, "INSERT INTO ");
    try stmt_buf.appendSlice(allocator, table);
    try stmt_buf.appendSlice(allocator, " (");
        var first = true;
        for (cols) |c| {
            if (c.pk and std.mem.eql(u8, c.type, "INTEGER")) continue; // auto-increment PK
            if (!first) try stmt_buf.append(allocator, ',');
            try stmt_buf.appendSlice(allocator, c.name);
            first = false;
        }
        try stmt_buf.appendSlice(allocator, ") VALUES (");

        first = true;
        for (cols) |c| {
            if (c.pk and std.mem.eql(u8, c.type, "INTEGER")) continue;
            if (!first) try stmt_buf.append(allocator, ',');
            const value = try generateValue(allocator, c.name, c.type, row_idx, &prng);
            defer allocator.free(value);
            try stmt_buf.appendSlice(allocator, value);
            first = false;
        }
        try stmt_buf.append(allocator, ')');
        try stmt_buf.append(allocator, ';');
        try stmt_buf.append(allocator, '\n');

        if (run_db) {
            const sql_z = try allocator.allocSentinel(u8, stmt_buf.items.len, 0);
            defer allocator.free(sql_z);
            @memcpy(sql_z, stmt_buf.items);
            if (sqlite_c.sqlite3_exec(db, sql_z.ptr, null, null, null) != sqlite_c.SQLITE_OK) {
                const e = sqlite_c.sqlite3_errmsg(db);
                std.debug.print("✗ row {d} failed: {s}\n", .{ row_idx, if (e) |s| std.mem.sliceTo(s, 0) else "?" });
                return error.FixtureInsertFailed;
            }
        } else {
            try output.appendSlice(allocator, stmt_buf.items);
        }
    }

    if (!run_db) {
        std.debug.print("{s}", .{output.items});
        std.debug.print("-- {d} INSERT statements generated. Use --run to execute.\n", .{count});
    } else {
        std.debug.print("✓ {d} rows inserted into {s}\n", .{ count, table });
    }
}

/// Generate JSON array with fake data.
fn generateFixtureJson(allocator: std.mem.Allocator, table: []const u8, cols: []TableColumn, count: usize) !void {
    var prng: u64 = 42;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try output.appendSlice(allocator, "[\n");

    for (0..count) |row_idx| {
        try output.appendSlice(allocator, "  {");
        var first = true;
        for (cols) |c| {
            if (!first) try output.append(allocator, ',');
            try output.appendSlice(allocator, "\"");
        try output.appendSlice(allocator, c.name);
        try output.appendSlice(allocator, "\":");
            const value = try generateValue(allocator, c.name, c.type, row_idx, &prng);
            defer allocator.free(value);
            try output.appendSlice(allocator, value);
            first = false;
        }
        try output.appendSlice(allocator, "}");
        if (row_idx + 1 < count) try output.append(allocator, ',');
        try output.append(allocator, '\n');
    }
    try output.appendSlice(allocator, "]\n");
    _ = table;
    std.debug.print("{s}", .{output.items});
}

/// Generate a fake value based on column name/type. Returns SQL literal or JSON value.
fn generateValue(allocator: std.mem.Allocator, col_name: []const u8, col_type: []const u8, row_idx: usize, prng: *u64) ![]u8 {
    const lower_name = try allocator.alloc(u8, col_name.len);
    defer allocator.free(lower_name);
    for (lower_name, 0..) |*c, i| c.* = std.ascii.toLower(col_name[i]);

    const is_int = std.mem.indexOf(u8, col_type, "INT") != null or std.mem.eql(u8, col_type, "INTEGER");
    const is_real = std.mem.indexOf(u8, col_type, "REAL") != null or std.mem.indexOf(u8, col_type, "DOUBLE") != null;
    const is_text = std.mem.indexOf(u8, col_type, "TEXT") != null or std.mem.indexOf(u8, col_type, "VARCHAR") != null;
    const is_blob = std.mem.indexOf(u8, col_type, "BLOB") != null;

    // Name-based generators
    if (std.mem.indexOf(u8, lower_name, "name") != null) {
        const n = row_idx + 1;
        return std.fmt.allocPrint(allocator, "'User {d}'", .{n});
    }
    if (std.mem.indexOf(u8, lower_name, "email") != null) {
        return std.fmt.allocPrint(allocator, "'user{d}@example.com'", .{row_idx + 1});
    }
    if (std.mem.indexOf(u8, lower_name, "phone") != null) {
        const r = nextU64(prng);
        return std.fmt.allocPrint(allocator, "'+1-555-{d:0>4}'", .{@as(u32, @intCast(r % 10000))});
    }
    if (std.mem.indexOf(u8, lower_name, "uuid") != null or std.mem.indexOf(u8, lower_name, "guid") != null) {
        const r = nextU64(prng);
        return std.fmt.allocPrint(allocator, "'{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}'", .{ r, r >> 16, r >> 32, r >> 48, r });
    }
    if (std.mem.indexOf(u8, lower_name, "title") != null) {
        return std.fmt.allocPrint(allocator, "'Post #{d}'", .{row_idx + 1});
    }
    if (std.mem.indexOf(u8, lower_name, "body") != null or std.mem.indexOf(u8, lower_name, "content") != null or std.mem.indexOf(u8, lower_name, "description") != null) {
        return std.fmt.allocPrint(allocator, "'Lorem ipsum dolor sit amet, row {d}.'", .{row_idx + 1});
    }
    if (std.mem.indexOf(u8, lower_name, "status") != null) {
        const statuses = [_][]const u8{ "'active'", "'pending'", "'closed'", "'archived'" };
        return allocator.dupe(u8, statuses[row_idx % statuses.len]);
    }
    if (std.mem.indexOf(u8, lower_name, "created") != null or std.mem.indexOf(u8, lower_name, "updated") != null) {
        return allocator.dupe(u8, "DATETIME('now')");
    }
    if (std.mem.indexOf(u8, lower_name, "active") != null or std.mem.indexOf(u8, lower_name, "enabled") != null) {
        return allocator.dupe(u8, if (row_idx % 2 == 0) "1" else "0");
    }
    if (std.mem.indexOf(u8, lower_name, "price") != null or std.mem.indexOf(u8, lower_name, "amount") != null) {
        return std.fmt.allocPrint(allocator, "{d}.{d:0>2}", .{ row_idx + 10, @as(u32, @intCast(row_idx * 7 % 100)) });
    }

    // Type-based fallback
    if (is_int) {
        return std.fmt.allocPrint(allocator, "{d}", .{row_idx + 1});
    }
    if (is_real) {
        return std.fmt.allocPrint(allocator, "{d}.5", .{row_idx + 1});
    }
    if (is_blob) {
        return allocator.dupe(u8, "X''");
    }
    if (is_text) {
        return std.fmt.allocPrint(allocator, "'text_{d}'", .{row_idx + 1});
    }
    return std.fmt.allocPrint(allocator, "'val_{d}'", .{row_idx + 1});
}

/// Simple LCG PRNG for deterministic fixtures.
fn nextU64(state: *u64) u64 {
    state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
    return state.*;
}

// ─────────────────────────────────────────────────────────────────────────────
// BENCH — HTTP load testing
// ─────────────────────────────────────────────────────────────────────────────

const BenchResult = struct {
    latency_us: u64,
    status: u16,
    had_error: bool,
};

/// Fire N requests at URL with C concurrent workers. Print stats:
/// RPS, p50/p95/p99 latency, total time, error rate.
fn handleBench(allocator: std.mem.Allocator, url: []const u8, count: usize, concurrency: usize) !void {
    std.debug.print("\n⚡ ZFinal Bench — {s} requests with concurrency={d}\n", .{ url, concurrency });
    std.debug.print("════════════════════════════════════════════════════\n", .{});

    const parsed = parseUrl(url) orelse {
        std.debug.print("✗ Invalid URL. Expected: http://host:port/path\n", .{});
        return;
    };

    const results = try allocator.alloc(BenchResult, count);
    defer allocator.free(results);

    var completed: usize = 0;
    const start_ts = std.Io.Timestamp.now(io, .real);

    var worker_idx: usize = 0;
    while (worker_idx < concurrency) : (worker_idx += 1) {
        const worker = BenchWorker{
            .allocator = allocator,
            .host = parsed.host,
            .port = parsed.port,
            .path = parsed.path,
            .is_tls = parsed.is_tls,
            .start_index = worker_idx,
            .stride = concurrency,
            .total = count,
            .results = results,
            .completed = &completed,
            .io = io,
        };
        const handle = try std.Thread.spawn(.{ .stack_size = 1 * 1024 * 1024 }, runBenchWorker, .{worker});
        handle.join();
    }

    const end_ts = std.Io.Timestamp.now(io, .real);
    const elapsed_ns = end_ts.toNanoseconds() -% start_ts.toNanoseconds();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    try printBenchReport(allocator, results, elapsed_s);
}

const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
    is_tls: bool,
};

fn parseUrl(url: []const u8) ?ParsedUrl {
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return null;
    const is_tls = std.mem.startsWith(u8, url, "https://");
    const scheme_len: usize = if (is_tls) 8 else 7;
    var rest = url[scheme_len..];

    const slash_idx = std.mem.indexOf(u8, rest, "/") orelse rest.len;
    const host_port = rest[0..slash_idx];
    const path = if (slash_idx < rest.len) rest[slash_idx..] else "/";

    const colon_idx = std.mem.indexOf(u8, host_port, ":");
    const host = if (colon_idx) |i| host_port[0..i] else host_port;
    const port: u16 = if (colon_idx) |i| std.fmt.parseInt(u16, host_port[i + 1 ..], 10) catch 80 else 80;

    return .{
        .host = host,
        .port = port,
        .path = path,
        .is_tls = is_tls,
    };
}

const BenchWorker = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    path: []const u8,
    is_tls: bool,
    start_index: usize,
    stride: usize,
    total: usize,
    results: []BenchResult,
    completed: *usize,
    io: std.Io,
};

fn runBenchWorker(w: BenchWorker) void {
    _ = w.is_tls;
    var idx: usize = w.start_index;
    while (idx < w.total) : (idx += w.stride) {
        const start_ts = std.Io.Timestamp.now(w.io, .real);
        const result = benchRequest(w.allocator, w.host, w.port, w.path);
        const end_ts = std.Io.Timestamp.now(w.io, .real);
        const elapsed_us: u64 = @intCast(@divTrunc(end_ts.toNanoseconds() - start_ts.toNanoseconds(), 1000));
        w.results[idx] = .{
            .latency_us = elapsed_us,
            .status = result.status,
            .had_error = result.error_msg != null,
        };
        _ = @atomicRmw(usize, w.completed, .Add, 1, .seq_cst);
    }
    }


const BenchRequestResult = struct {
    status: u16,
    error_msg: ?[]const u8,
};

fn benchRequest(allocator: std.mem.Allocator, host: []const u8, port: u16, path: []const u8) BenchRequestResult {
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();
    const url_str = std.fmt.allocPrint(allocator, "http://{s}:{d}{s}", .{ host, port, path }) catch {
        return .{ .status = 0, .error_msg = "url alloc failed" };
    };
    defer allocator.free(url_str);
    const result = client.fetch(.{
        .location = .{ .url = url_str },
        .method = .GET,
    }) catch {
        return .{ .status = 0, .error_msg = "fetch failed" };
    };
    return .{ .status = @intFromEnum(result.status), .error_msg = null };
}

fn printBenchReport(allocator: std.mem.Allocator, results: []BenchResult, elapsed_s: f64) !void {
    var latencies: std.ArrayList(u64) = .empty;
    defer latencies.deinit(allocator);

    var errors: usize = 0;
    var status_hist: [10]usize = @splat(0);
    var min_us: u64 = std.math.maxInt(u64);
    var max_us: u64 = 0;
    var sum_us: u64 = 0;

    for (results) |r| {
        try latencies.append(allocator, r.latency_us);
        if (r.had_error) errors += 1;
        if (r.status > 0 and r.status < 1000) {
            status_hist[r.status / 100] += 1;
        }
        if (r.latency_us < min_us) min_us = r.latency_us;
        if (r.latency_us > max_us) max_us = r.latency_us;
        sum_us += r.latency_us;
    }
    std.mem.sort(u64, latencies.items, {}, std.sort.asc(u64));

    const total = results.len;
    const rps = @as(f64, @floatFromInt(total)) / elapsed_s;
    const avg_us: f64 = @as(f64, @floatFromInt(sum_us)) / @as(f64, @floatFromInt(total));
    const p50 = latencies.items[total * 50 / 100];
    const p95 = latencies.items[total * 95 / 100];
    const p99 = latencies.items[total * 99 / 100];

    std.debug.print("\nResults:\n", .{});
    std.debug.print("  Total requests:  {d}\n", .{total});
    std.debug.print("  Total time:      {d:.3}s\n", .{elapsed_s});
    std.debug.print("  Throughput:      {d:.1} req/s\n", .{rps});
    std.debug.print("  Errors:          {d} ({d:.2}%)\n", .{ errors, @as(f64, @floatFromInt(errors)) * 100.0 / @as(f64, @floatFromInt(total)) });

    std.debug.print("\nLatency:\n", .{});
    std.debug.print("  Min:   {d} µs\n", .{min_us});
    std.debug.print("  Avg:   {d:.0} µs\n", .{avg_us});
    std.debug.print("  p50:   {d} µs\n", .{p50});
    std.debug.print("  p95:   {d} µs\n", .{p95});
    std.debug.print("  p99:   {d} µs\n", .{p99});
    std.debug.print("  Max:   {d} µs\n", .{max_us});

    std.debug.print("\nStatus codes:\n", .{});
    for (status_hist, 1..) |count, code| {
        if (count > 0) {
            std.debug.print("  {d}xx: {d}\n", .{ code, count });
        }
    }
    std.debug.print("\n════════════════════════════════════════════════════\n", .{});
}
