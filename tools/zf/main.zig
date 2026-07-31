const std = @import("std");
const templates = @import("templates.zig");
const zf_cfg = @import("zf_cfg");
const zf_shared = @import("zf_shared.zig");

const writeFile = zf_shared.writeFile;
const capitalizeOwned = zf_shared.capitalizeOwned;
const hasFlag = zf_shared.hasFlag;
const ensureDir = zf_shared.ensureDir;

const cmd_migrate = @import("cmd_migrate.zig");
const cmd_openapi = @import("cmd_openapi.zig");
const cmd_check = @import("cmd_check.zig");
const cmd_routes = @import("cmd_routes.zig");
const cmd_crud = @import("cmd_crud.zig");
const cmd_fixture = @import("cmd_fixture.zig");
const cmd_bench = @import("cmd_bench.zig");
const cmd_port = @import("cmd_port.zig");
const cmd_gate = @import("cmd_gate.zig");
const cmd_market = @import("cmd_market.zig");

const handleMigrate = cmd_migrate.handleMigrate;
const handleSeed = cmd_migrate.handleSeed;
const handleOpenapi = cmd_openapi.handleOpenapi;
const printOpenapiHelp = cmd_openapi.printOpenapiHelp;
const handleCheck = cmd_check.handleCheck;
const handleCrud = cmd_crud.handleCrud;
const handleCrudFromDsn = cmd_crud.handleCrudFromDsn;
const handleCrudZent = cmd_crud.handleCrudZent;
const handleCrudFromSql = cmd_crud.handleCrudFromSql;
const handleAdmin = cmd_crud.handleAdmin;
const handleFixture = cmd_fixture.handleFixture;
const handleBench = cmd_bench.handleBench;
const appendJsonString = zf_shared.appendJsonString;
const writeAiConfigs = zf_shared.writeAiConfigs;

/// libc getenv — Zig 0.17 std doesn't expose it uniformly.
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

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
    crud_zent,
    crud_dsn,
    check,
    upgrade,
    life,
    admin,
    seed,
    fixture,
    bench,
    ai,
    openapi,
    routes,
    gate,
    release_check,
    market,
};

pub fn main(init: std.process.Init) !void {
    zf_shared.io = init.io;
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
                std.debug.print("Usage: {s} generate <type> <name> [--json] [--force]\n", .{args[0]});
                std.debug.print("Types: handler, model, middleware, service, task, port\n", .{});
                std.debug.print("      port names: store | cache | bus  (L2/L3 ports + adapters)\n", .{});
                std.debug.print("Flags: --json   Emit machine-readable manifest.\n", .{});
                std.debug.print("       --force  Overwrite existing files.\n", .{});
                return;
            }
            const json_mode = hasFlag(args, "--json");
            const force = hasFlag(args, "--force");
            try generateCode(allocator, args[2], args[3], false, json_mode, force);
        },
        .api => {
            if (args.len < 3) {
                std.debug.print("Usage: {s} api <name>\n", .{args[0]});
                std.debug.print("Generate API handler (JSON output)\n", .{});
                return;
            }
            try generateCode(allocator, "handler", args[2], true, false, false);
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
        .ai => {
            // zf ai <prompt...> [--provider openai|anthropic] [--model <model>]
            if (args.len < 3) {
                std.debug.print("Usage: {s} ai <prompt...> [--provider openai|anthropic] [--model <name>]\n", .{args[0]});
                std.debug.print("  Ask an LLM about your ZFinal project. Auto-loads AGENTS.md + last zf check output.\n", .{});
                std.debug.print("  Set OPENAI_API_KEY or ANTHROPIC_API_KEY environment variable.\n", .{});
                return;
            }
            // Join all non-flag args as the prompt
            var prompt_buf: std.ArrayList(u8) = .empty;
            defer prompt_buf.deinit(allocator);
            var provider: []const u8 = "openai";
            var model: []const u8 = "gpt-4o-mini";
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--provider") and i + 1 < args.len) {
                    provider = args[i + 1];
                    i += 1;
                } else if (std.mem.eql(u8, args[i], "--model") and i + 1 < args.len) {
                    model = args[i + 1];
                    i += 1;
                } else {
                    if (prompt_buf.items.len > 0) try prompt_buf.append(allocator, ' ');
                    try prompt_buf.appendSlice(allocator, args[i]);
                }
            }
            try handleAi(allocator, prompt_buf.items, provider, model);
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
                std.debug.print("  --force       Overwrite existing files (skip ai-edit-zone merge)\n", .{});
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
        .crud_zent => {
            if (args.len < 3) {
                std.debug.print("Usage: {s} crud:zent <schema.zent|schema.json> [--force] [--json] [--explain] [--dry-run] [--out <dir>]\n", .{args[0]});
                std.debug.print("  Generate zent-primary module: model/persistence/service/handler/routes.\n", .{});
                std.debug.print("  AI-first: always pass --json; edit only ai-edit-zone blocks.\n", .{});
                std.debug.print("  --force    Overwrite existing files (skip zone merge; else merge ai-edit-zones or write *.gen.new)\n", .{});
                std.debug.print("  --json     Emit machine-readable manifest for AI agents\n", .{});
                std.debug.print("  --explain  Print plan + AI edit zones before writing\n", .{});
                std.debug.print("  --dry-run  Print plan only; do not write files\n", .{});
                std.debug.print("  --out dir  Output root (default: src/modules)\n", .{});
                return;
            }
            const force = hasFlag(args, "--force");
            const json_mode = hasFlag(args, "--json");
            const explain_mode = hasFlag(args, "--explain");
            const dry_run = hasFlag(args, "--dry-run");
            const out_dir = blk: {
                var i: usize = 3;
                while (i + 1 < args.len) : (i += 1) {
                    if (std.mem.eql(u8, args[i], "--out")) break :blk args[i + 1];
                }
                break :blk "src/modules";
            };
            try handleCrudZent(allocator, args[2], out_dir, force, json_mode, explain_mode, dry_run);
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
            const prod = hasFlag(args, "--prod");
            const prod_root = zf_shared.flagValue(args, "--root") orelse "examples/production";
            if (zf_shared.flagValue(args, "--root") != null and !prod) {
                std.debug.print("Note: --root implies --prod\n", .{});
            }
            const do_prod = prod or zf_shared.flagValue(args, "--root") != null;
            try handleCheck(allocator, heal, ai_zones, do_prod, prod_root);
        },
        .upgrade => {
            try handleUpgrade(allocator);
        },
        .life => {
            const sub = if (args.len > 2) args[2] else "status";
            try handleLife(allocator, sub, if (args.len > 3) args[3] else "");
        },
        .openapi => {
            var out_path: []const u8 = "openapi.yaml";
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
                    out_path = args[i + 1];
                    i += 1;
                } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
                    printOpenapiHelp(args[0]);
                    return;
                } else {
                    std.debug.print("Unknown flag: {s}\n", .{args[i]});
                    printOpenapiHelp(args[0]);
                    return;
                }
            }
            try handleOpenapi(allocator, out_path);
        },
        .routes => {
            try cmd_routes.handleRoutes(allocator, args);
        },
        .gate => {
            try cmd_gate.handleGate(allocator, args);
        },
        .release_check => {
            try cmd_gate.handleReleaseCheck(allocator, args);
        },
        .market => {
            try cmd_market.handleMarket(allocator, args);
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
    if (std.mem.eql(u8, cmd, "crud:zent")) return .crud_zent;
    if (std.mem.eql(u8, cmd, "admin")) return .admin;
    if (std.mem.eql(u8, cmd, "crud:dsn")) return .crud_dsn;
    if (std.mem.eql(u8, cmd, "check")) return .check;
    if (std.mem.eql(u8, cmd, "upgrade")) return .upgrade;
    if (std.mem.eql(u8, cmd, "life")) return .life;
    if (std.mem.eql(u8, cmd, "seed")) return .seed;
    if (std.mem.eql(u8, cmd, "fixture")) return .fixture;
    if (std.mem.eql(u8, cmd, "bench")) return .bench;
    if (std.mem.eql(u8, cmd, "ai")) return .ai;
    if (std.mem.eql(u8, cmd, "openapi")) return .openapi;
    if (std.mem.eql(u8, cmd, "routes")) return .routes;
    if (std.mem.eql(u8, cmd, "gate")) return .gate;
    if (std.mem.eql(u8, cmd, "release-check")) return .release_check;
    if (std.mem.eql(u8, cmd, "market")) return .market;
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
    std.debug.print("  generate, g <type> <name>  Generate code (handler, model, middleware, service, task, port)\n", .{});
    std.debug.print("                            port: store|cache|bus → src/ports + src/adapters\n", .{});
    std.debug.print("  api <name>              Generate API handler (JSON output)\n", .{});
    std.debug.print("  migrate <action> [name] Manage database migrations\n", .{});
    std.debug.print("  test:gen <name>         Generate test file\n", .{});
    std.debug.print("  crud <db> <table>       Generate full CRUD from SQLite DB schema\n", .{});
    std.debug.print("  crud:sql <file> [name]  Generate from .sql file (DB/Model data layer).\n", .{});
    std.debug.print("  crud:zent <file>        Generate from .zent/.json (zent primary data layer).\n", .{});
    std.debug.print("  admin <file>            Generate vben-style admin HTML (htmx + alpine + tailwind, CDN)\n", .{});
    std.debug.print("  check                   Audit project for AI compliance (gen/ext boundaries)\n", .{});
    std.debug.print("  check --prod [--root R] Production-contract scan (default root: examples/production)\n", .{});
    std.debug.print("  upgrade                 Upgrade zfinal dependency to latest release\n", .{});
    std.debug.print("  docker                  Generate Dockerfile\n", .{});
    std.debug.print("  deploy                  Deploy application\n", .{});
    std.debug.print("  build, b                Build release binary\n", .{});
    std.debug.print("  serve, s                Start development server (zig build run)\n", .{});
    std.debug.print("  test, t                 Run tests (zig build test)\n", .{});
    std.debug.print("  version, v              Show version information\n", .{});
    std.debug.print("  openapi [--out <file>]  Generate minimal OpenAPI 3.0.3 spec from project routes\n", .{});
    std.debug.print("  routes [--json] [--check] [--root DIR]\n", .{});
    std.debug.print("                            Generate routes.zig from modules/**/actions.zig\n", .{});
    std.debug.print("  gate [--quick|--full|--release]  Productized quality gate (scripts/quality_gate.sh)\n", .{});
    std.debug.print("  release-check           Pre-tag gate (alias: gate --release)\n", .{});
    std.debug.print("  market <list|search|info>  Local module marketplace catalog\n", .{});
    std.debug.print("  help, h                 Show this help message\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Examples:\n", .{});
    std.debug.print("  {s} new myapp           Create a new project named 'myapp'\n", .{exe_name});
    std.debug.print("  {s} crud:sql schema.sql --json\n", .{exe_name});
    std.debug.print("  {s} crud:zent schema.zent --json   # zent primary (e-commerce/social)\n", .{exe_name});
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
    try cwd.createDirPath(zf_shared.io, project_name);
    var project_dir = try cwd.openDir(zf_shared.io, project_name, .{});
    defer project_dir.close(zf_shared.io);

    std.debug.print("\nCreating project: {s}\n", .{project_name});

    const app_name = std.fs.path.basename(project_name);

    // Root: build.zig + build.zig.zon + CLAUDE.md
    const build_zig_content = try std.fmt.allocPrint(allocator, templates.build_zig, .{app_name});
    defer allocator.free(build_zig_content);
    try writeFile(project_dir, "build.zig", build_zig_content);

    const build_zon_content = try std.fmt.allocPrint(allocator, templates.build_zig_zon, .{app_name});
    defer allocator.free(build_zon_content);
    try writeFile(project_dir, "build.zig.zon", build_zon_content);

    const claude_md_content = try std.fmt.allocPrint(allocator, templates.claude_md, .{project_name});
    defer allocator.free(claude_md_content);
    try writeFile(project_dir, "CLAUDE.md", claude_md_content);

    // AI tool configs (.claude/, .opencode/, .cursor/)
    try writeAiConfigs(allocator, project_dir);

    // docker-compose.yml + Dockerfile — single-binary deployment
    try writeDeploymentFiles(allocator, project_dir, project_name);

    // src/
    try project_dir.createDirPath(zf_shared.io, "src");
    var src_dir = try project_dir.openDir(zf_shared.io, "src", .{});
    defer src_dir.close(zf_shared.io);

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
    try src_dir.createDirPath(zf_shared.io, "handler");
    if (!clean) {
        var handler_dir = try src_dir.openDir(zf_shared.io, "handler", .{});
        defer handler_dir.close(zf_shared.io);
        const index_content = try std.fmt.allocPrint(allocator, templates.handler_index_zig, .{project_name});
        defer allocator.free(index_content);
        try writeFile(handler_dir, "index.zig", index_content);
        try writeFile(handler_dir, "user.zig", templates.handler_user_zig);
    }

    // src/service/ — business logic layer
    try src_dir.createDirPath(zf_shared.io, "service");

    // src/model/
    try src_dir.createDirPath(zf_shared.io, "model");
    if (!clean) {
        var model_dir = try src_dir.openDir(zf_shared.io, "model", .{});
        defer model_dir.close(zf_shared.io);
        try writeFile(model_dir, "user.zig", templates.model_user_zig);
    }

    // src/middleware/
    try src_dir.createDirPath(zf_shared.io, "middleware");
    if (!clean) {
        var middleware_dir = try src_dir.openDir(zf_shared.io, "middleware", .{});
        defer middleware_dir.close(zf_shared.io);
        try writeFile(middleware_dir, "auth.zig", templates.middleware_auth_zig);
    }

    // src/common/
    try src_dir.createDirPath(zf_shared.io, "common");
    var common_dir = try src_dir.openDir(zf_shared.io, "common", .{});
    defer common_dir.close(zf_shared.io);
    try writeFile(common_dir, "constants.zig", templates.common_constants_zig);
    try writeFile(common_dir, "errors.zig", templates.common_errors_zig);

    // test/
    try project_dir.createDirPath(zf_shared.io, "test");
    try project_dir.createDirPath(zf_shared.io, "test/handler");

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

fn generateCode(allocator: std.mem.Allocator, gen_type: []const u8, name: []const u8, is_api: bool, json_mode: bool, force: bool) !void {
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
    } else if (std.mem.eql(u8, gen_type, "port")) {
        try cmd_port.generatePort(allocator, name, force, json_mode);
        return; // manifest already emitted by cmd_port when json_mode
    } else {
        std.debug.print("Unknown type: {s}\n", .{gen_type});
        std.debug.print("Available: handler, model, middleware, service, task, port\n", .{});
        return;
    }

    if (json_mode) {
        var out_buf = std.ArrayList(u8).empty;
        defer out_buf.deinit(allocator);
        try out_buf.appendSlice(allocator, "{\n");
        try out_buf.appendSlice(allocator, "  \"$schema\": \"https://zfinal.dev/schemas/manifest-1.json\",\n");
        try out_buf.appendSlice(allocator, "  \"version\": \"");
        try out_buf.appendSlice(allocator, zf_cfg.semver);
        try out_buf.appendSlice(allocator, "\",\n");
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
        try out.writeStreamingAll(zf_shared.io, out_buf.items);
    }
}

fn generateHandler(allocator: std.mem.Allocator, name: []const u8, is_api: bool) !void {
    std.Io.Dir.cwd().access(zf_shared.io, "src/handler", .{}) catch {
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

    try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = filename, .data = content });
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
    std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = test_filename, .data = test_content }) catch {};
}

fn generateModel(allocator: std.mem.Allocator, name: []const u8) !void {
    std.Io.Dir.cwd().access(zf_shared.io, "src/model", .{}) catch {
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

    try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = filename, .data = content });
    std.debug.print("✅ Generated model: {s}\n", .{filename});
}

fn generateMiddleware(allocator: std.mem.Allocator, name: []const u8) !void {
    std.Io.Dir.cwd().access(zf_shared.io, "src/middleware", .{}) catch {
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

    try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = filename, .data = content });
    std.debug.print("✅ Generated: {s}\n", .{filename});
}

fn generateService(allocator: std.mem.Allocator, name: []const u8) !void {
    std.Io.Dir.cwd().access(zf_shared.io, "src/service", .{}) catch {
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

    try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = filename, .data = content });
    std.debug.print("✅ Generated: {s}\n", .{filename});
}

fn generateTask(allocator: std.mem.Allocator, name: []const u8) !void {
    std.Io.Dir.cwd().access(zf_shared.io, "src/task", .{}) catch {
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

    try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = filename, .data = content });
    std.debug.print("✅ Generated: {s}\n", .{filename});
}

fn generateTest(allocator: std.mem.Allocator, name: []const u8) !void {
    const test_dir = "test";
    std.Io.Dir.cwd().createDirPath(zf_shared.io, test_dir) catch |err| {
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

    try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = filename, .data = content });
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

    try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = "Dockerfile", .data = dockerfile_content });
    std.debug.print("✅ Generated Dockerfile\n", .{});

    const dockerignore_content =
        \\zig-cache/
        \\zig-out/
        \\.git/
        \\.github/
        \\*.md
        \\
    ;

    try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = ".dockerignore", .data = dockerignore_content });
    std.debug.print("✅ Generated .dockerignore\n", .{});
}

fn handleDeploy(allocator: std.mem.Allocator) !void {
    const deploy_script = "deploy.sh";

    // Check if deploy script exists
    std.Io.Dir.cwd().access(zf_shared.io, deploy_script, .{}) catch {
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
        try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = deploy_script, .data = content });

        // Make executable
        _ = try std.process.run(allocator, zf_shared.io, .{
            .argv = &[_][]const u8{ "chmod", "+x", deploy_script },
        });

        std.debug.print("✅ Created default deployment script: {s}\n", .{deploy_script});
        std.debug.print("Please edit it to match your deployment needs.\n", .{});
        return;
    };

    // Run existing deploy script
    std.debug.print("Running deployment script...\n", .{});
    const result = try std.process.run(allocator, zf_shared.io, .{
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
    std.Io.Dir.cwd().createDirPath(zf_shared.io, plugin_dir) catch |err| {
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

        try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = filename, .data = content });
        std.debug.print("✅ Generated generic plugin: {s}\n", .{filename});
    }
}

fn handleLife(allocator: std.mem.Allocator, sub: []const u8, _: []const u8) !void {
    if (std.mem.eql(u8, sub, "status")) {
        // Check if .life directory exists
        std.Io.Dir.cwd().access(zf_shared.io, ".life", .{}) catch {
            std.debug.print("No .life directory found. Run 'zf life init' first.\n", .{});
            return;
        };
        std.debug.print("Project Life Status\n", .{});
        std.debug.print("==================\n", .{});
        std.debug.print("Directory: .life/ exists\n", .{});
        std.debug.print("Fingerprints: ", .{});
        var fp_dir = std.Io.Dir.cwd().openDir(zf_shared.io, ".life/fingerprints", .{ .iterate = true }) catch {
            std.debug.print("none\n", .{});
            return;
        };
        defer fp_dir.close(zf_shared.io);
        var it = fp_dir.iterate();
        var count: usize = 0;
        while (try it.next(zf_shared.io)) |entry| {
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
        const ts = std.Io.Timestamp.now(zf_shared.io, .real).toSeconds();
        std.debug.print("Timestamp: {d}\n", .{ts});
        std.debug.print("Fingerprint: zf-{d}\n", .{ts});
    } else {
        std.debug.print("Unknown life command: {s}\n", .{sub});
        std.debug.print("Available: init, status, fingerprint\n", .{});
    }
}

/// Upgrade zfinal dependency to the latest release (auto-executes zig fetch).
fn handleUpgrade(allocator: std.mem.Allocator) !void {
    const latest = zf_cfg.version;
    std.debug.print("\n⬆️  zf upgrade (target: {s})\n", .{latest});

    // Read current build.zig.zon
    const zon_file = std.Io.Dir.cwd().openFile(zf_shared.io, "build.zig.zon", .{}) catch {
        std.debug.print("   ⚠️  No build.zig.zon — not in a zfinal project?\n", .{});
        return;
    };
    defer zon_file.close(zf_shared.io);

    const stat = zon_file.stat(zf_shared.io) catch return;
    var zon_buf = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(zon_buf);
    _ = std.Io.File.readPositionalAll(zon_file, zf_shared.io, zon_buf, 0) catch {
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
    const result = std.process.run(allocator, zf_shared.io, .{ .argv = &.{ "zig", "fetch", "--save", url } }) catch {
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

fn copyPluginFile(allocator: std.mem.Allocator, filename: []const u8) !void {
    const dest_path = try std.fmt.allocPrint(allocator, "src/plugin/{s}", .{filename});
    defer allocator.free(dest_path);

    // Check if we are in the ZFinal repo
    const src_path = try std.fmt.allocPrint(allocator, "src/plugin/{s}", .{filename});
    defer allocator.free(src_path);

    std.Io.Dir.cwd().access(zf_shared.io, src_path, .{}) catch {
        std.debug.print("⚠️  Could not find source plugin file: {s}\n", .{src_path});
        std.debug.print("Please ensure you are running this from the ZFinal repository root for now.\n", .{});
        return;
    };

    try std.Io.Dir.cwd().copyFile(src_path, std.Io.Dir.cwd(), dest_path, zf_shared.io, .{});
    std.debug.print("✅ Installed plugin: {s}\n", .{dest_path});
}

// ─────────────────────────────────────────────────────────────────────────────
// AI — interactive LLM assistant with ZFinal context
// ─────────────────────────────────────────────────────────────────────────────

/// Send `prompt` to an LLM with ZFinal context loaded.
/// Currently supports OpenAI's chat completions API.
/// Context includes: AGENTS.md (if present), .claude/skills (filenames), recent zf check output.
/// Send prompt to OpenAI-compatible LLM with ZFinal context loaded.
/// Loads AGENTS.md + .claude/skills/, builds request, POSTs via std.http.Client,
/// parses response, prints the assistant message.
fn handleAi(allocator: std.mem.Allocator, prompt: []const u8, provider: []const u8, model: []const u8) !void {
    // 1. Read API key from environment
    const api_key_ptr = getenv("OPENAI_API_KEY");
    const api_key: []const u8 = if (api_key_ptr) |p| std.mem.sliceTo(p, 0) else {
        std.debug.print("✗ OPENAI_API_KEY not set.\n", .{});
        std.debug.print("  export OPENAI_API_KEY=sk-...\n", .{});
        return;
    };
    if (api_key.len == 0) {
        std.debug.print("✗ OPENAI_API_KEY is empty.\n", .{});
        return;
    }

    // 2. Build context (AGENTS.md + skills listing)
    var context_buf: std.ArrayList(u8) = .empty;
    defer context_buf.deinit(allocator);

    if (readFileIfExists(allocator, "AGENTS.md")) |agents| {
        defer allocator.free(agents);
        try context_buf.appendSlice(allocator, "\n# Project: AGENTS.md\n\n");
        try context_buf.appendSlice(allocator, agents);
    } else |_| {}

    if (std.Io.Dir.cwd().openDir(zf_shared.io, ".claude/skills", .{})) |skills_dir| {
        defer std.Io.Dir.close(skills_dir, zf_shared.io);
        try context_buf.appendSlice(allocator, "\n# Available skills\n");
        var it = skills_dir.iterate();
        while (it.next(zf_shared.io) catch null) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md")) {
                const s = try std.fmt.allocPrint(allocator, "- {s}\n", .{entry.name});
                try context_buf.appendSlice(allocator, s);
            }
        }
    } else |_| {}

    // 3. Build full user message: context + question
    var user_msg: std.ArrayList(u8) = .empty;
    defer user_msg.deinit(allocator);
    try user_msg.appendSlice(allocator, prompt);
    if (context_buf.items.len > 0) {
        try user_msg.appendSlice(allocator, "\n\n---\n# Project context:\n");
        try user_msg.appendSlice(allocator, context_buf.items);
    }

    // 4. Build JSON request body
    const system_msg = "You are an expert ZFinal AI assistant. ZFinal is a Zig web framework with a CLI tool 'zf' that generates code. Use the project context to answer accurately. Be concise.";

    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(allocator);
    try body_buf.appendSlice(allocator, "{\"model\":\"");
    try body_buf.appendSlice(allocator, model);
    try body_buf.appendSlice(allocator, "\",\"messages\":[");
    const sys_escaped = try jsonEscape(allocator, system_msg);
    defer allocator.free(sys_escaped);
    try body_buf.appendSlice(allocator, "{\"role\":\"system\",\"content\":");
    try body_buf.appendSlice(allocator, sys_escaped);
    try body_buf.appendSlice(allocator, "},");
    const user_escaped = try jsonEscape(allocator, user_msg.items);
    defer allocator.free(user_escaped);
    try body_buf.appendSlice(allocator, "{\"role\":\"user\",\"content\":");
    try body_buf.appendSlice(allocator, user_escaped);
    try body_buf.appendSlice(allocator, "}]}");

    // 5. Build Authorization header
    const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    std.debug.print("\n🤖 ZFinal AI ({s}/{s}) — {d} bytes context\n", .{ provider, model, context_buf.items.len });
    std.debug.print("════════════════════════════════════════════════════\n", .{});

    // 6. HTTP POST via std.http.Client
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = zf_shared.io,
    };
    defer client.deinit();

    const url = "https://api.openai.com/v1/chat/completions";

    // Allocate a buffer for response body
    var response_buf = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(response_buf);
    const response_writer = std.Io.Writer.fixed(response_buf);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .extra_headers = &[_]std.http.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = auth_header },
        },
        .payload = body_buf.items,
        .response_writer = @constCast(&response_writer),
    }) catch |err| {
        std.debug.print("✗ HTTP request failed: {t}\n", .{err});
        std.debug.print("  (offline? check OPENAI_API_KEY)\n", .{});
        return;
    };

    std.debug.print("HTTP {d} ", .{@intFromEnum(result.status)});
    if (@intFromEnum(result.status) >= 200 and @intFromEnum(result.status) < 300) {
        std.debug.print("✓\n\n", .{});
    } else {
        std.debug.print("✗ (error)\n", .{});
    }

    // 7. Extract assistant message from response JSON.
    if (response_writer.end == 0) {
        std.debug.print("(no response body)\n", .{});
        return;
    }
    const body_str = response_buf[0..response_writer.end];
    if (extractAssistantContent(allocator, body_str)) |content| {
        defer allocator.free(content);
        std.debug.print("{s}\n", .{content});
    } else |_| {
        std.debug.print("(could not parse assistant content from response)\n", .{});
        std.debug.print("--- Raw response ---\n{s}\n", .{body_str});
    }
}

/// Extract "content": "..." value from OpenAI chat completion response.
/// Naive parser — finds first "content":" or "content": " and reads to next unescaped quote.
fn extractAssistantContent(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    const needle = "\"content\":";
    const idx = std.mem.indexOf(u8, json, needle) orelse return &[_]u8{};
    var pos: usize = idx + needle.len;
    while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t' or json[pos] == '\n')) : (pos += 1) {}
    if (pos >= json.len or json[pos] != '"') return &[_]u8{};
    pos += 1;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    while (pos < json.len) {
        const c = json[pos];
        if (c == '\\' and pos + 1 < json.len) {
            const next = json[pos + 1];
            switch (next) {
                'n' => try out.append(allocator, '\n'),
                't' => try out.append(allocator, '\t'),
                'r' => try out.append(allocator, '\r'),
                '"' => try out.append(allocator, '"'),
                '\\' => try out.append(allocator, '\\'),
                '/' => try out.append(allocator, '/'),
                else => try out.append(allocator, next),
            }
            pos += 2;
        } else if (c == '"') {
            break;
        } else {
            try out.append(allocator, c);
            pos += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Escape a string for JSON embedding.
fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0...7, 11, 12, 14...31 => {
                const s2 = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{c});
                try buf.appendSlice(allocator, s2);
            },
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
    return buf.toOwnedSlice(allocator);
}

/// Read a file into memory, or return error if not found.
fn readFileIfExists(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, path);
    const f = try std.Io.Dir.cwd().openFile(zf_shared.io, path_z, .{});
    defer f.close(zf_shared.io);
    const stat = try f.stat(zf_shared.io);
    if (stat.size > 100_000) return &[_]u8{}; // skip huge files
    const content = try allocator.alloc(u8, @intCast(stat.size));
    _ = try std.Io.File.readPositionalAll(f, zf_shared.io, content, 0);
    return content;
}

/// Best-effort: run `zf check` and capture output for AI context.
fn runZfCheckCapture(allocator: std.mem.Allocator) ![]u8 {
    _ = allocator;
    // TODO: actually spawn `zf check` and capture stdout.
    return &[_]u8{};
}

/// Write docker-compose.yml + Dockerfile for single-binary deployment.
/// Container names are derived from project_name (lowercased, dashes → underscores).
fn writeDeploymentFiles(allocator: std.mem.Allocator, cwd: std.Io.Dir, project_name: []const u8) !void {
    const app_name_lower = try allocator.dupe(u8, project_name);
    defer allocator.free(app_name_lower);
    // Lowercase + replace '-' with '_' for container-friendly names.
    for (app_name_lower) |*c| {
        if (c.* == '-') c.* = '_';
        c.* = std.ascii.toLower(c.*);
    }
    // docker-compose.yml uses {s} three times: image, container_name,
    // POSTGRES_DB (commented template).
    const compose_content = try std.fmt.allocPrint(
        allocator,
        templates.docker_compose,
        .{ app_name_lower, app_name_lower, app_name_lower },
    );
    defer allocator.free(compose_content);
    try writeFile(cwd, "docker-compose.yml", compose_content);

    // Dockerfile uses {s} twice: zig-out/bin/<name> and <name>_server.
    const dockerfile_content = try std.fmt.allocPrint(
        allocator,
        templates.dockerfile,
        .{ project_name, project_name },
    );
    defer allocator.free(dockerfile_content);
    try writeFile(cwd, "Dockerfile", dockerfile_content);
}
