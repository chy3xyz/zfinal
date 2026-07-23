//! `zf openapi` — generate minimal OpenAPI 3.0.3 YAML from project routes.
const std = @import("std");
const openapi = @import("openapi");
const zf_shared = @import("zf_shared.zig");

const readFileAlloc = zf_shared.readFileAlloc;
const safeWrite = zf_shared.safeWrite;

// ============================================================
// OPENAPI — generate minimal OpenAPI 3.0.3 spec from project routes
// ============================================================

/// Default source roots scanned by `zf openapi`. Skips `.zig-cache`,
/// `zig-out`, and `.zig-pkg` — generated/dependency trees don't define
/// real routes and would only slow down parsing.
const openapi_skip_dirs = [_][]const u8{
    ".zig-cache",
    "zig-out",
    "zig-pkg",
    "node_modules",
    ".git",
};

/// Collect all `.zig` files under `root`, skipping cache/dependency trees.
fn collectOpenapiSources(
    allocator: std.mem.Allocator,
    root: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var dir = std.Io.Dir.cwd().openDir(zf_shared.io, root, .{}) catch return;
    defer std.Io.Dir.close(dir, zf_shared.io);

    for (openapi_skip_dirs) |skip| {
        if (std.mem.eql(u8, root, skip)) return;
    }

    var it = dir.iterate();
    while (try it.next(zf_shared.io)) |entry| {
        const sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, entry.name });

        var skip_child = false;
        for (openapi_skip_dirs) |skip| {
            if (std.mem.eql(u8, entry.name, skip)) {
                skip_child = true;
                break;
            }
        }
        if (skip_child) {
            allocator.free(sub_path);
            continue;
        }

        if (entry.kind == .directory) {
            try collectOpenapiSources(allocator, sub_path, out);
            allocator.free(sub_path);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            try out.append(allocator, sub_path);
        } else {
            allocator.free(sub_path);
        }
    }
}

/// Concatenate the source text of every path in `paths` into a single
/// buffer (separated by newlines) so the parser sees one continuous
/// document.
fn concatSources(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    for (paths) |path| {
        const content = readFileAlloc(allocator, path) catch continue;
        defer allocator.free(content);
        try buf.appendSlice(allocator, content);
        try buf.append(allocator, '\n');
    }
    return buf.toOwnedSlice(allocator);
}

/// Generate `openapi.yaml` (or wherever `--out` points) from the project's
/// route definitions. Sources scanned: `src/**/*.zig` plus the root
/// `main.zig` if present. Existing output is preserved via `safeWrite`
/// (written to `<path>.gen.new`) unless the caller removes it first.
pub fn handleOpenapi(allocator: std.mem.Allocator, out_path: []const u8) !void {
    std.debug.print("\n📜 zf openapi — scanning project routes\n", .{});
    std.debug.print("════════════════════════════════════════\n\n", .{});

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    try collectOpenapiSources(allocator, "src", &paths);

    // Top-level main.zig is conventionally outside src/.
    if (std.Io.Dir.cwd().access(zf_shared.io, "main.zig", .{}) != error.FileNotFound) {
        const main_path = try allocator.dupe(u8, "main.zig");
        try paths.append(allocator, main_path);
    }

    if (paths.items.len == 0) {
        std.debug.print("⚠️  No .zig files found under src/ or ./main.zig.\n", .{});
        std.debug.print("   Run from a zfinal project root, or generate one with `zf new`.\n", .{});
        return;
    }

    std.debug.print("   scanning {d} file(s)\n", .{paths.items.len});
    const source = try concatSources(allocator, paths.items);
    defer allocator.free(source);

    var spec = openapi.parse(allocator, source) catch |err| {
        std.debug.print("error: openapi parse failed: {t}\n", .{err});
        return err;
    };
    defer spec.deinit();

    const yaml = try openapi.renderYaml(allocator, spec);
    defer allocator.free(yaml);

    std.debug.print("   routes found: {d}\n", .{spec.routes.items.len});

    // safeWrite: merge ai-edit-zones when present; else `.gen.new`.
    // OpenAPI YAML usually has no zones → expect `.gen.new` on re-run.
    try safeWrite(allocator, out_path, yaml, false);
    std.debug.print("\nTip: feed this file to Swagger UI / Redoc / openapi-generator.\n", .{});
}

pub fn printOpenapiHelp(exe_name: []const u8) void {
    std.debug.print("\n", .{});
    std.debug.print("Usage: {s} openapi [--out <path>]\n", .{exe_name});
    std.debug.print("\n", .{});
    std.debug.print("Generate a minimal OpenAPI 3.0.3 YAML spec from your project's\n", .{});
    std.debug.print("static route registrations.\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Scope (v0.20):\n", .{});
    std.debug.print("  - Recognises app.get/post/put/patch/delete(...)\n", .{});
    std.debug.print("  - Recognises app.<method>WithInterceptors(...)\n", .{});
    std.debug.print("  - Recognises RouteGroup.init(&app, \"/prefix\") + group.<method>(...)\n", .{});
    std.debug.print("  - Normalises :id → {{id}} and renders path parameters\n", .{});
    std.debug.print("  - Dedupes by (method, path), stable sort\n", .{});
    std.debug.print("  - Emits info(title, version) and per-operation '200' response\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Sources scanned: src/**/*.zig + ./main.zig (if present).\n", .{});
    std.debug.print("Skipped: .zig-cache, zig-out, zig-pkg, node_modules, .git.\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Output:\n", .{});
    std.debug.print("  --out <file>   Destination path (default: openapi.yaml).\n", .{});
    std.debug.print("                 If the file exists, output goes to <file>.gen.new\n", .{});
    std.debug.print("                 for manual review (same policy as zf crud:sql).\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Out of scope (v0.20): request/response schemas, security, body types.\n", .{});
}
