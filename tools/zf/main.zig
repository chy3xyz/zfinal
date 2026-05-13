const std = @import("std");
const templates = @import("templates.zig");
const codegen = @import("codegen.zig");

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
                std.debug.print("Generate API controller (JSON output)\n", .{});
                return;
            }
            try generateCode(allocator, "controller", args[2], true);
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
    std.debug.print("  generate, g <type> <name>  Generate code (controller, model, interceptor, plugin)\n", .{});
    std.debug.print("  api <name>              Generate API controller (JSON output)\n", .{});
    std.debug.print("  migrate <action> [name] Manage database migrations\n", .{});
    std.debug.print("  test:gen <name>         Generate test file\n", .{});
    std.debug.print("  crud <db> <table>       Generate full CRUD from SQLite DB schema\n", .{});
    std.debug.print("  crud:sql <file>         Generate migration package from SQL dump\n", .{});
    std.debug.print("  docker                  Generate Dockerfile\n", .{});
    std.debug.print("  deploy                  Deploy application\n", .{});
    std.debug.print("  build, b                Build release binary\n", .{});
    std.debug.print("  serve, s                Start development server (zig build run)\n", .{});
    std.debug.print("  test, t                 Run tests (zig build test)\n", .{});
    std.debug.print("  version, v              Show version information\n", .{});
    std.debug.print("  help, h                 Show this help message\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Examples:\n", .{});
    std.debug.print("  {s} new myapp           Create a new HTMX project named 'myapp'\n", .{exe_name});
    std.debug.print("  {s} g controller User   Generate UserController (HTMX)\n", .{exe_name});
    std.debug.print("  {s} api Product         Generate ProductController (API/JSON)\n", .{exe_name});
    std.debug.print("  {s} migrate new init    Create initial migration\n", .{exe_name});
    std.debug.print("  {s} test:gen User       Generate User test\n", .{exe_name});
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

    std.debug.print("Creating project: {s}\n", .{project_name});

    // Create build.zig
    const build_zig_content = try std.fmt.allocPrint(allocator, templates.build_zig, .{project_name});
    defer allocator.free(build_zig_content);
    try writeFile(project_dir, "build.zig", build_zig_content);

    // Create build.zig.zon
    const build_zon_content = try std.fmt.allocPrint(allocator, templates.build_zig_zon, .{project_name});
    defer allocator.free(build_zon_content);
    try writeFile(project_dir, "build.zig.zon", build_zon_content);

    // Create src directory
    try project_dir.createDirPath(io, "src");
    var src_dir = try project_dir.openDir(io, "src", .{});
    defer src_dir.close(io);

    // src/main.zig
    try writeFile(src_dir, "main.zig", templates.main_zig);

    // src/config
    try src_dir.createDirPath(io, "config");
    var config_dir = try src_dir.openDir(io, "config", .{});
    defer config_dir.close(io);
    try writeFile(config_dir, "config.zig", templates.config_config_zig);
    try writeFile(config_dir, "routes.zig", templates.config_routes_zig);
    try writeFile(config_dir, "db_init.zig", templates.config_db_init_zig);

    // src/controller
    try src_dir.createDirPath(io, "controller");
    var controller_dir = try src_dir.openDir(io, "controller", .{});
    defer controller_dir.close(io);
    try writeFile(controller_dir, "index_controller.zig", templates.controller_index_controller_zig);

    // src/model
    try src_dir.createDirPath(io, "model");
    var model_dir = try src_dir.openDir(io, "model", .{});
    defer model_dir.close(io);
    try writeFile(model_dir, "user.zig", templates.model_user_zig);

    // src/interceptor
    try src_dir.createDirPath(io, "interceptor");
    var interceptor_dir = try src_dir.openDir(io, "interceptor", .{});
    defer interceptor_dir.close(io);
    try writeFile(interceptor_dir, "interceptors.zig", templates.interceptor_interceptors_zig);

    std.debug.print("✅ Project '{s}' created successfully!\n", .{project_name});
    std.debug.print("\n", .{});
    std.debug.print("Next steps:\n", .{});
    std.debug.print("  cd {s}\n", .{project_name});
    std.debug.print("  zig build run\n", .{});
    std.debug.print("\n", .{});
}

fn generateCode(allocator: std.mem.Allocator, gen_type: []const u8, name: []const u8, is_api: bool) !void {
    if (name.len == 0) {
        std.debug.print("Error: Name is required\n", .{});
        return;
    }

    if (std.mem.eql(u8, gen_type, "controller")) {
        try generateController(allocator, name, is_api);
    } else if (std.mem.eql(u8, gen_type, "model")) {
        try generateModel(allocator, name);
    } else if (std.mem.eql(u8, gen_type, "interceptor")) {
        try generateInterceptor(allocator, name);
    } else if (std.mem.eql(u8, gen_type, "plugin")) {
        try generatePlugin(allocator, name);
    } else {
        std.debug.print("Unknown type: {s}\n", .{gen_type});
        std.debug.print("Available types: controller, model, interceptor, plugin\n", .{});
    }
}

fn generateController(allocator: std.mem.Allocator, name: []const u8, is_api: bool) !void {
    // Check if src/controller directory exists
    std.Io.Dir.cwd().access(io, "src/controller", .{}) catch {
        std.debug.print("Error: src/controller directory not found. Are you in a ZFinal project?\n", .{});
        return;
    };

    const name_lower = try std.ascii.allocLowerString(allocator, name);
    defer allocator.free(name_lower);

    const filename = try std.fmt.allocPrint(allocator, "src/controller/{s}_controller.zig", .{name_lower});
    defer allocator.free(filename);

    const controller_name = try capitalizeOwned(allocator, name);
    defer allocator.free(controller_name);

    const controller_type_comment = if (is_api) "API Controller (JSON output)" else "HTMX Controller (HTML output)";

    const content = try std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\const zfinal = @import("zfinal");
        \\
        \\/// {s}
        \\pub const {s}Controller = struct {{
        \\    /// List all {s}s
        \\    pub fn index(ctx: *zfinal.Context) !void {{
        \\        try ctx.renderJson(.{{
        \\            .message = "{s} list",
        \\            .data = .{{}},
        \\        }});
        \\    }}
        \\
        \\    /// Show a single {s}
        \\    pub fn show(ctx: *zfinal.Context) !void {{
        \\        const id = ctx.getPathParam("id") orelse {{
        \\            ctx.res_status = .bad_request;
        \\            try ctx.renderJson(.{{ .@"error" = "Missing ID" }});
        \\            return;
        \\        }};
        \\
        \\        try ctx.renderJson(.{{
        \\            .id = id,
        \\            .message = "{s} details",
        \\        }});
        \\    }}
        \\
        \\    /// Create a new {s}
        \\    pub fn create(ctx: *zfinal.Context) !void {{
        \\        try ctx.renderJson(.{{
        \\            .message = "{s} created",
        \\        }});
        \\    }}
        \\
        \\    /// Update a {s}
        \\    pub fn update(ctx: *zfinal.Context) !void {{
        \\        const id = ctx.getPathParam("id") orelse {{
        \\            ctx.res_status = .bad_request;
        \\            try ctx.renderJson(.{{ .@"error" = "Missing ID" }});
        \\            return;
        \\        }};
        \\
        \\        try ctx.renderJson(.{{
        \\            .id = id,
        \\            .message = "{s} updated",
        \\        }});
        \\    }}
        \\
        \\    /// Delete a {s}
        \\    pub fn delete(ctx: *zfinal.Context) !void {{
        \\        const id = ctx.getPathParam("id") orelse {{
        \\            ctx.res_status = .bad_request;
        \\            try ctx.renderJson(.{{ .@"error" = "Missing ID" }});
        \\            return;
        \\        }};
        \\
        \\        try ctx.renderJson(.{{
        \\            .id = id,
        \\            .message = "{s} deleted",
        \\        }});
        \\    }}
        \\}};
        \\
    , .{ controller_type_comment, controller_name, name_lower, name_lower, name_lower, name_lower, name_lower, name_lower, name_lower, name_lower, name_lower, name_lower });
    defer allocator.free(content);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = filename, .data = content });
    const mode_str = if (is_api) "API" else "HTMX";
    std.debug.print("✅ Generated {s} controller: {s}\n", .{ mode_str, filename });

    if (!is_api) {
        // Generate HTMX template
        const templates_path = "src/templates";
        std.Io.Dir.cwd().createDirPath(io, templates_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const view_dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ templates_path, name_lower });
        defer allocator.free(view_dir_path);

        std.Io.Dir.cwd().createDirPath(io, view_dir_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const view_file_path = try std.fmt.allocPrint(allocator, "{s}/index.html", .{view_dir_path});
        defer allocator.free(view_file_path);

        const view_content = try std.fmt.allocPrint(allocator,
            \\<div id="{s}-list">
            \\    <h2>{s} List</h2>
            \\    <button hx-get="/{s}/create" hx-target="#{s}-list" hx-swap="afterend">
            \\        Create New {s}
            \\    </button>
            \\    
            \\    <div class="list-content">
            \\        <!-- List items will be rendered here -->
            \\        <p>No items found.</p>
            \\    </div>
            \\</div>
            \\
        , .{ name_lower, controller_name, name_lower, name_lower, controller_name });
        defer allocator.free(view_content);

        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = view_file_path, .data = view_content });
        std.debug.print("✅ Generated HTMX template: {s}\n", .{view_file_path});
    }
}

fn generateModel(allocator: std.mem.Allocator, name: []const u8) !void {
    // Check if src/model directory exists
    std.Io.Dir.cwd().access(io, "src/model", .{}) catch {
        std.debug.print("Error: src/model directory not found. Are you in a ZFinal project?\n", .{});
        return;
    };

    const name_lower = try std.ascii.allocLowerString(allocator, name);
    defer allocator.free(name_lower);

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
    std.debug.print("✅ Generated: {s}\n", .{filename});
}

fn generateInterceptor(allocator: std.mem.Allocator, name: []const u8) !void {
    // Check if src/interceptor directory exists
    std.Io.Dir.cwd().access(io, "src/interceptor", .{}) catch {
        std.debug.print("Error: src/interceptor directory not found. Are you in a ZFinal project?\n", .{});
        return;
    };

    const name_lower = try std.ascii.allocLowerString(allocator, name);
    defer allocator.free(name_lower);

    const filename = try std.fmt.allocPrint(allocator, "src/interceptor/{s}_interceptor.zig", .{name_lower});
    defer allocator.free(filename);

    const interceptor_name = try capitalizeOwned(allocator, name);
    defer allocator.free(interceptor_name);

    const content = try std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\const zfinal = @import("zfinal");
        \\
        \\fn {s}Before(ctx: *zfinal.Context) !bool {{
        \\    std.debug.print("{s} interceptor: before\n", .{{}});
        \\    return true; // Continue to next interceptor/handler
        \\}}
        \\
        \\fn {s}After(ctx: *zfinal.Context) !void {{
        \\    std.debug.print("{s} interceptor: after\n", .{{}});
        \\}}
        \\
        \\pub const {s}Interceptor = zfinal.Interceptor{{
        \\    .name = "{s}",
        \\    .before = {s}Before,
        \\    .after = {s}After,
        \\}};
        \\
    , .{ name_lower, interceptor_name, name_lower, interceptor_name, interceptor_name, name_lower, name_lower, name_lower });
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

    try writeGeneratedFiles(allocator, &table);
}

fn handleCrudFromSql(allocator: std.mem.Allocator, sql_path: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, sql_path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    var content = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(content);
    const n = try std.Io.File.readPositionalAll(file, io, content, 0);
    content = content[0..n];

    var tables = try codegen.parseSqlFile(allocator, content);
    defer {
        for (tables.items) |*t| t.deinit();
        tables.deinit(allocator);
    }

    std.debug.print("Parsed {d} tables from {s}\n", .{ tables.items.len, sql_path });

    // Generate combined migration package
    const pkg = try codegen.generateMigrationPackage(allocator, tables.items);
    defer allocator.free(pkg);

    const out_path = try std.fmt.allocPrint(allocator, "zfinal_migration.zig", .{});
    defer allocator.free(out_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = pkg });

    std.debug.print("✅ Generated migration package: {s}\n", .{out_path});
    std.debug.print("   Copy model/controller files to your project src/\n", .{});
    std.debug.print("   Add routes from the generated file to your config/routes.zig\n", .{});

    // Also generate individual files for each table
    for (tables.items) |*table| {
        try writeGeneratedFiles(allocator, table);
    }
}

fn writeGeneratedFiles(allocator: std.mem.Allocator, table: *codegen.Table) !void {
    // deps.zig — shared dependencies (generated once per project)
    try ensureDir(allocator, "src");
    const deps_content =
        \\const zfinal = @import("zfinal");
        \\pub var pool: zfinal.ConnectionPool = undefined;
        \\
    ;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "src/deps.zig", .data = deps_content }) catch {};

    // Model
    const model = try codegen.generateModel(allocator, table);
    defer allocator.free(model);
    const model_path = try std.fmt.allocPrint(allocator, "src/model/{s}.zig", .{table.name});
    defer allocator.free(model_path);
    try ensureDir(allocator, "src/model");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = model_path, .data = model });
    std.debug.print("✅ Generated model: {s}\n", .{model_path});

    // Controller
    const ctrl = try codegen.generateController(allocator, table);
    defer allocator.free(ctrl);
    const ctrl_path = try std.fmt.allocPrint(allocator, "src/controller/{s}_controller.zig", .{table.name});
    defer allocator.free(ctrl_path);
    try ensureDir(allocator, "src/controller");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ctrl_path, .data = ctrl });
    std.debug.print("✅ Generated controller: {s}\n", .{ctrl_path});

    // Routes
    const routes = try codegen.generateRoutes(allocator, table);
    defer allocator.free(routes);
    std.debug.print("✅ Routes for {s}:\n{s}\n", .{ table.name, routes });

    // Test
    const test_code = try codegen.generateTest(allocator, table);
    defer allocator.free(test_code);
    const test_path = try std.fmt.allocPrint(allocator, "test/{s}_test.zig", .{table.name});
    defer allocator.free(test_path);
    try ensureDir(allocator, "test");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = test_path, .data = test_code });
    std.debug.print("✅ Generated test: {s}\n", .{test_path});
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
