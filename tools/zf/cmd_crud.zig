//! `zf crud` / `zf crud:sql` / `zf crud:zent` / `zf crud:dsn` / `zf admin` handlers.
const std = @import("std");
const templates = @import("templates.zig");
const codegen = @import("codegen");
const zent_codegen = @import("zent_codegen");
const csql = @import("csql.zig");
const zf_cfg = @import("zf_cfg");
const zf_shared = @import("zf_shared.zig");
const zf_db = @import("zf_db.zig");
const admin_templates = @import("admin_templates.zig");

const sqlite_c = zf_db.sqlite_c;
const writeFile = zf_shared.writeFile;
const readFileAlloc = zf_shared.readFileAlloc;
const pascalCaseConvert = zf_shared.pascalCaseConvert;
const safeWrite = zf_shared.safeWrite;
const ensureDir = zf_shared.ensureDir;
const appendJsonString = zf_shared.appendJsonString;
const writeAiConfigs = zf_shared.writeAiConfigs;

/// Generate vben-style admin HTML files for every table in a SQL file.
/// Each table produces 4 files: admin.html, admin_form.html, admin_row.html
/// plus a shared layout.html at the output root.
pub fn handleAdmin(allocator: std.mem.Allocator, sql_path: []const u8, out_dir: []const u8) !void {
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
    const dir = std.Io.Dir.createDirPathOpen(.cwd(), zf_shared.io, out_dir, .{}) catch |e| {
        std.debug.print("error: cannot create {s}: {t}\n", .{ out_dir, e });
        return e;
    };
    defer std.Io.Dir.close(dir, zf_shared.io);

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
        const module_dir = std.Io.Dir.createDirPathOpen(dir, zf_shared.io, module_dir_path, .{}) catch |e| {
            std.debug.print("error: cannot create {s}/{s}: {t}\n", .{ out_dir, table.name, e });
            return e;
        };
        defer std.Io.Dir.close(module_dir, zf_shared.io);

        try writeFile(module_dir, "admin.html", files.list);
        try writeFile(module_dir, "admin_form.html", files.form);
        try writeFile(module_dir, "admin_row.html", files.row);
        written += 1;
    }

    std.debug.print("✅ Generated {d} module(s) × 3 admin files (multi-table sidebar)\n", .{written});
    std.debug.print("   Edit ai-edit-zones in each file to customize.\n", .{});
}

pub fn handleCrud(allocator: std.mem.Allocator, db_path: []const u8, table_name: []const u8) !void {
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

pub fn handleCrudFromDsn(allocator: std.mem.Allocator, dsn_url: []const u8) !void {
    // Auto-bootstrap if needed
    // Check if project exists by trying to open build.zig.zon
    const zon_file = std.Io.Dir.cwd().openFile(zf_shared.io, "build.zig.zon", .{});
    if (zon_file) |f| {
        f.close(zf_shared.io);
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
    try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = out_path, .data = pkg });
    std.debug.print("✅ Generated migration package: {s}\n", .{out_path});

    for (tables.items) |*table| {
        const mp = try modulePath(allocator, table.name);
        defer allocator.free(mp);
        try writeGeneratedFiles(allocator, table, mp, false);
    }
    try generateIntegrationTestEntry(allocator, tables.items);
}

pub fn handleCrudZent(
    allocator: std.mem.Allocator,
    schema_path: []const u8,
    out_root: []const u8,
    force: bool,
    json_mode: bool,
    explain_mode: bool,
    dry_run: bool,
) !void {
    const content = readFileAlloc(allocator, schema_path) catch |e| {
        std.debug.print("error: cannot read {s}: {t}\n", .{ schema_path, e });
        return e;
    };
    defer allocator.free(content);

    var schema = zent_codegen.parseFile(allocator, schema_path, content) catch |e| {
        std.debug.print("error: failed to parse {s}: {t}\n", .{ schema_path, e });
        return e;
    };
    defer schema.deinit();

    std.debug.print("zent schema: module={s} entities={d} api={s}\n", .{
        schema.module,
        schema.entities.items.len,
        schema.api_prefix,
    });
    for (schema.entities.items) |ent| {
        std.debug.print("  • {s} ({d} fields", .{ ent.name, ent.fields.items.len });
        if (ent.list_by) |lb| std.debug.print(", list_by={s}", .{lb});
        std.debug.print(")\n", .{});
    }

    if (explain_mode or dry_run) {
        std.debug.print("\n──── zf crud:zent plan (AI) ────\n", .{});
        std.debug.print("data_layer: zent (primary)\n", .{});
        std.debug.print("module path: {s}/{s}/\n", .{ out_root, schema.module });
        std.debug.print("generated: model.zig, persistence.zig, service.zig, handler.zig, routes.zig\n", .{});
        std.debug.print("ai-edit-zones:\n", .{});
        std.debug.print("  • model.zig        → model hooks (edges / privacy)\n", .{});
        std.debug.print("  • persistence.zig  → custom queries\n", .{});
        std.debug.print("  • service.zig      → business rules / extra methods\n", .{});
        std.debug.print("  • handler.zig      → handler hooks / extra routes\n", .{});
        std.debug.print("rules: edit ONLY ai-edit-zones; never mix zfinal.DB + zent Tx\n", .{});
        if (dry_run) {
            const boot = try zent_codegen.generateBootstrapSnippet(allocator, &schema);
            defer allocator.free(boot);
            std.debug.print("\n{s}\n", .{boot});
            std.debug.print("[dry-run] exiting without writing files.\n", .{});
            return;
        }
        std.debug.print("\n──── continue ────\n", .{});
    }

    if (dry_run) {
        std.debug.print("\n[dry-run] would write under {s}/{s}/:\n", .{ out_root, schema.module });
        std.debug.print("  model.zig persistence.zig service.zig handler.zig routes.zig\n", .{});
        const boot = try zent_codegen.generateBootstrapSnippet(allocator, &schema);
        defer allocator.free(boot);
        std.debug.print("\n{s}\n", .{boot});
        return;
    }

    const mod_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ out_root, schema.module });
    defer allocator.free(mod_dir);
    try std.Io.Dir.cwd().createDirPath(zf_shared.io, mod_dir);

    const model = try zent_codegen.generateModel(allocator, &schema);
    defer allocator.free(model);
    const persist = try zent_codegen.generatePersistence(allocator, &schema);
    defer allocator.free(persist);
    const service = try zent_codegen.generateService(allocator, &schema);
    defer allocator.free(service);
    const handler = try zent_codegen.generateHandler(allocator, &schema);
    defer allocator.free(handler);
    const routes = try zent_codegen.generateRoutes(allocator, &schema);
    defer allocator.free(routes);

    const model_path = try std.fmt.allocPrint(allocator, "{s}/model.zig", .{mod_dir});
    defer allocator.free(model_path);
    const persist_path = try std.fmt.allocPrint(allocator, "{s}/persistence.zig", .{mod_dir});
    defer allocator.free(persist_path);
    const service_path = try std.fmt.allocPrint(allocator, "{s}/service.zig", .{mod_dir});
    defer allocator.free(service_path);
    const handler_path = try std.fmt.allocPrint(allocator, "{s}/handler.zig", .{mod_dir});
    defer allocator.free(handler_path);
    const routes_path = try std.fmt.allocPrint(allocator, "{s}/routes.zig", .{mod_dir});
    defer allocator.free(routes_path);

    try safeWrite(allocator, model_path, model, force);
    try safeWrite(allocator, persist_path, persist, force);
    try safeWrite(allocator, service_path, service, force);
    try safeWrite(allocator, handler_path, handler, force);
    try safeWrite(allocator, routes_path, routes, force);

    const boot = try zent_codegen.generateBootstrapSnippet(allocator, &schema);
    defer allocator.free(boot);
    std.debug.print("\n── bootstrap (wire in main.zig) ──\n{s}\n", .{boot});

    if (json_mode) {
        const manifest = try zent_codegen.emitJsonManifest(allocator, schema_path, &schema);
        defer allocator.free(manifest);
        var out = std.Io.File.stdout();
        try out.writeStreamingAll(zf_shared.io, manifest);
    }
}

pub fn handleCrudFromSql(allocator: std.mem.Allocator, sql_path: []const u8, project_name: ?[]const u8, force: bool, json_mode: bool, admin_mode: bool, explain_mode: bool, dry_run: bool) !void {
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
        std.Io.Dir.cwd().createDirPath(zf_shared.io, name) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        const name_z = try allocator.allocSentinel(u8, name.len, 0);
        @memcpy(name_z, name);
        defer allocator.free(name_z);
        _ = std.c.chdir(name_z.ptr);
    }

    // Auto-bootstrap project if not already in one
    // Check if project exists by trying to open build.zig.zon
    const zon_file = std.Io.Dir.cwd().openFile(zf_shared.io, "build.zig.zon", .{});
    if (zon_file) |f| {
        f.close(zf_shared.io);
    } else |_| {
        std.debug.print("⚡ Bootstrapping clean project...\n", .{});
        try bootstrapProject(allocator);
    }

    const file = try std.Io.Dir.cwd().openFile(zf_shared.io, resolved_sql, .{});
    defer file.close(zf_shared.io);

    const stat = try file.stat(zf_shared.io);
    var content = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(content);
    const n = try std.Io.File.readPositionalAll(file, zf_shared.io, content, 0);
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
    try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = out_path, .data = pkg });

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
        const dir = std.Io.Dir.createDirPathOpen(.cwd(), zf_shared.io, out_dir, .{}) catch |e| {
            std.debug.print("error: cannot create {s}: {t}\n", .{ out_dir, e });
            return e;
        };
        defer std.Io.Dir.close(dir, zf_shared.io);

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
            const module_dir = std.Io.Dir.createDirPathOpen(dir, zf_shared.io, table.name, .{}) catch |e| {
                std.debug.print("error: cannot create {s}/{s}: {t}\n", .{ out_dir, table.name, e });
                return e;
            };
            defer std.Io.Dir.close(module_dir, zf_shared.io);
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
    try out.writeStreamingAll(zf_shared.io, buf.items);
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

    try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = "src/modules/manifest.gen.zig", .data = buf.items });
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
        std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = "src/deps.zig", .data = deps }) catch {};
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
    try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = test_gen_path, .data = test_code });
    std.debug.print("✅ Generated test: {s}\n", .{test_gen_path});

    // ── Integration test (full-stack: handler→service→model→DB) ──
    try ensureDir(allocator, "test/integration");
    const int_test = try codegen.generateIntegrationTest(allocator, table, module_name);
    defer allocator.free(int_test);
    const int_test_path = try std.fmt.allocPrint(allocator, "test/integration/{s}_int_test.gen.zig", .{module_name});
    defer allocator.free(int_test_path);
    try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = int_test_path, .data = int_test });
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

    try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = "test/integration/runner.zig", .data = content });
    std.debug.print("✅ Generated integration runner: test/integration/runner.zig\n", .{});
}

/// Bootstrap minimal project in CWD — no demo files, ready for zf crud:sql.
fn bootstrapProject(allocator: std.mem.Allocator) !void {
    const cwd = std.Io.Dir.cwd();

    // build.zig
    const build_zig_content = try std.fmt.allocPrint(allocator, templates.build_zig, .{"app"});
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
    try cwd.createDirPath(zf_shared.io, "src");
    var src_dir = try cwd.openDir(zf_shared.io, "src", .{});
    defer src_dir.close(zf_shared.io);

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
    try src_dir.createDirPath(zf_shared.io, "common");
    var common_dir = try src_dir.openDir(zf_shared.io, "common", .{});
    defer common_dir.close(zf_shared.io);
    try writeFile(common_dir, "constants.zig", templates.common_constants_zig);
    try writeFile(common_dir, "errors.zig", templates.common_errors_zig);

    // src/validator/
    try src_dir.createDirPath(zf_shared.io, "validator");
    var validator_dir = try src_dir.openDir(zf_shared.io, "validator", .{});
    defer validator_dir.close(zf_shared.io);
    try writeFile(validator_dir, "validate.zig", templates.validator_validate);

    // src/task/
    try src_dir.createDirPath(zf_shared.io, "task");
    var task_dir = try src_dir.openDir(zf_shared.io, "task", .{});
    defer task_dir.close(zf_shared.io);
    try writeFile(task_dir, "runner.zig", templates.task_runner);

    // test/
    try cwd.createDirPath(zf_shared.io, "test");
    try cwd.createDirPath(zf_shared.io, "test/handler");

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
