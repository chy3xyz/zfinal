const std = @import("std");
const zf_cfg = @import("zf_cfg");
const zf_shared = @import("zf_shared.zig");

const hasFlag = zf_shared.hasFlag;

const cmd_migrate = @import("cmd_migrate.zig");
const cmd_openapi = @import("cmd_openapi.zig");
const cmd_check = @import("cmd_check.zig");
const cmd_routes = @import("cmd_routes.zig");
const cmd_crud = @import("cmd_crud.zig");
const cmd_fixture = @import("cmd_fixture.zig");
const cmd_bench = @import("cmd_bench.zig");
const cmd_gate = @import("cmd_gate.zig");
const cmd_market = @import("cmd_market.zig");
const cmd_catalog = @import("cmd_catalog.zig");
const cmd_doctor = @import("cmd_doctor.zig");
const cmd_scaffold = @import("cmd_scaffold.zig");

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

const Command = cmd_catalog.Command;

pub fn main(init: std.process.Init) !void {
    zf_shared.io = init.io;
    zf_shared.environ_map = init.environ_map;
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
        cmd_catalog.printHelp(argv0);
        return;
    };

    const command = cmd_catalog.parseCommand(command_str) orelse {
        std.debug.print("Unknown command: {s}\n", .{command_str});
        if (cmd_catalog.suggestCommand(command_str)) |sug| {
            std.debug.print("Did you mean: {s}?\n", .{sug});
        }
        std.debug.print("\nIf this binary lacks routes/gate/doctor, rebuild:\n", .{});
        std.debug.print("  zig build install-zf && ./zig-out/bin/zf {s}\n\n", .{command_str});
        cmd_catalog.printHelp(argv0);
        std.process.exit(zf_shared.Exit.fail);
    };

    switch (command) {
        .new => {
            if (args.len < 3) {
                std.debug.print("Usage: {s} new <project_name> [--clean] [--json]\n", .{argv0});
                std.debug.print("  --clean  Skip demo files (handler/user.zig, model/user.zig)\n", .{});
                std.debug.print("  --json   Emit machine-readable manifest on stdout\n", .{});
                return;
            }
            const clean = hasFlag(args, "--clean");
            const json_mode = hasFlag(args, "--json");
            try cmd_scaffold.createProject(allocator, args[2], clean, json_mode);
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
            try cmd_scaffold.generateCode(allocator, args[2], args[3], false, json_mode, force);
        },
        .api => {
            if (args.len < 3) {
                std.debug.print("Usage: {s} api <name>\n", .{args[0]});
                std.debug.print("Generate API handler (JSON output)\n", .{});
                return;
            }
            try cmd_scaffold.generateCode(allocator, "handler", args[2], true, false, false);
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
            // zf ai <prompt...> [--provider openai|anthropic|deepseek] [--model <model>]
            if (args.len < 3) {
                std.debug.print("Usage: {s} ai <prompt...> [--provider openai|anthropic|deepseek] [--model <name>]\n", .{args[0]});
                std.debug.print("  Ask an LLM about your ZFinal project. Auto-loads AGENTS.md + last zf check output.\n", .{});
                std.debug.print("  Set OPENAI_API_KEY, ANTHROPIC_API_KEY, or DEEPSEEK_API_KEY.\n", .{});
                std.debug.print("  DeepSeek default model: deepseek-v4-flash (deepseek-chat retired).\n", .{});
                return;
            }
            // Join all non-flag args as the prompt
            var prompt_buf: std.ArrayList(u8) = .empty;
            defer prompt_buf.deinit(allocator);
            var provider: []const u8 = "openai";
            var model: ?[]const u8 = null;
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
            const resolved_model = model orelse if (std.mem.eql(u8, provider, "deepseek"))
                "deepseek-v4-flash"
            else if (std.mem.eql(u8, provider, "anthropic"))
                "claude-haiku-4-5-20251001"
            else
                "gpt-4o-mini";
            try cmd_scaffold.handleAi(allocator, prompt_buf.items, provider, resolved_model);
        },
        .test_gen => {
            if (args.len < 3) {
                std.debug.print("Usage: {s} test:gen <name>\n", .{args[0]});
                return;
            }
            try cmd_scaffold.generateTest(allocator, args[2]);
        },
        .docker => try cmd_scaffold.generateDocker(allocator),
        .deploy => try cmd_scaffold.handleDeploy(allocator),
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
            std.debug.print("semver {s} · Zig Web Framework inspired by JFinal\n", .{zf_cfg.semver});
            std.debug.print("Install tip: zig build install-zf && ./zig-out/bin/zf\n", .{});
        },
        .help => cmd_catalog.printHelp(args[0]),
        .doctor => {
            try cmd_doctor.handleDoctor(allocator, args);
        },
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
            const practice = hasFlag(args, "--practice");
            const practice_strict = hasFlag(args, "--strict");
            const root_flag = zf_shared.flagValue(args, "--root");
            const prod_root = root_flag orelse "examples/production";
            const practice_root = root_flag orelse ".";
            if (root_flag != null and !prod and !practice) {
                std.debug.print("Note: --root alone implies --prod (add --practice to audit without prod contract)\n", .{});
            }
            // --root alone ⇒ prod (compat); --practice --root ⇒ practice only unless --prod too.
            const do_prod = prod or (root_flag != null and !practice);
            const do_deadcode = hasFlag(args, "--deadcode");
            var dc_paths_buf: [8][]const u8 = undefined;
            var dc_paths_len: usize = 0;
            if (zf_shared.flagValue(args, "--deadcode-root")) |p| {
                dc_paths_buf[0] = p;
                dc_paths_len = 1;
            }
            // Extra positional paths after flags: `zf check --deadcode src tools`
            {
                var i: usize = 2;
                while (i < args.len) : (i += 1) {
                    const a = args[i];
                    if (a.len >= 2 and a[0] == '-' and a[1] == '-') {
                        // skip flag values
                        if (std.mem.eql(u8, a, "--root") or std.mem.eql(u8, a, "--deadcode-root")) i += 1;
                        continue;
                    }
                    if (dc_paths_len < dc_paths_buf.len) {
                        dc_paths_buf[dc_paths_len] = a;
                        dc_paths_len += 1;
                    }
                }
            }
            const dc_opts = cmd_check.DeadcodeOpts{
                .paths = if (dc_paths_len > 0) dc_paths_buf[0..dc_paths_len] else &.{},
                .binary = hasFlag(args, "--deadcode-binary") or hasFlag(args, "-b"),
                .include_pub = hasFlag(args, "--include-pub") or hasFlag(args, "-p"),
                .no_tests = hasFlag(args, "--no-tests") or hasFlag(args, "-n"),
                .no_members = hasFlag(args, "--no-members") or hasFlag(args, "-m"),
                .no_files = hasFlag(args, "--no-files") or hasFlag(args, "-F"),
                .no_gitignore = hasFlag(args, "--no-gitignore") or hasFlag(args, "-g"),
                .json = hasFlag(args, "--deadcode-json") or (do_deadcode and hasFlag(args, "--json")),
                .verbose = hasFlag(args, "--verbose") or hasFlag(args, "-v"),
                .warn_only = hasFlag(args, "--deadcode-warn"),
            };
            try handleCheck(allocator, heal, ai_zones, do_prod, prod_root, do_deadcode, dc_opts, practice, practice_strict, practice_root);
        },
        .upgrade => {
            try cmd_scaffold.handleUpgrade(allocator);
        },
        .life => {
            const sub = if (args.len > 2) args[2] else "status";
            try cmd_scaffold.handleLife(allocator, sub, if (args.len > 3) args[3] else "");
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
