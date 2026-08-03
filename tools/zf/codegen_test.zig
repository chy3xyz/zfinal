//! Regression tests for the `zf` code generator. Run with
//! `zig build test-zf` (registered in build.zig).
//!
//! Verifies that the templates for model/service/handler/routes
//! produce compilable code with the expected structure:
//!   - @generated header
//!   - ai-edit-zone markers
//!   - pascal_case table name
//!   - snake_case fields
//!   - valid Zig syntax (parses with std.zig.Tokenizer)

const std = @import("std");
const codegen = @import("codegen");
const zent_codegen = @import("zent_codegen");
const zone_merge = @import("zone_merge");
test "zone_merge: preserves named ai-edit-zone body" {
    const allocator = std.testing.allocator;
    const existing =
        \\// ── ai-edit-zone: business rules ──
        \\    try validate(x);
        \\// ── end ai-edit-zone ──
        \\
    ;
    const generated =
        \\// ── ai-edit-zone: business rules ──
        \\    // TODO
        \\// ── end ai-edit-zone ──
        \\
    ;
    const merged = try zone_merge.mergeAiEditZones(allocator, existing, generated);
    defer if (merged) |m| allocator.free(m);
    try std.testing.expect(merged != null);
    try std.testing.expect(std.mem.indexOf(u8, merged.?, "try validate(x);") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged.?, "// TODO") == null);
}
/// Run `body` with a `*codegen.Table` parsed from a single CREATE TABLE
/// statement. Cleans up tables array and the borrowed Table after the
/// body returns. Avoids lifetime gotchas with ArrayList by-pointer.
fn withTable(allocator: std.mem.Allocator, sql: []const u8, body: *const fn (t: *codegen.Table) anyerror!void) !void {
    var tables = try codegen.parseSqlFile(allocator, sql);
    defer {
        for (tables.items) |*t| t.deinit();
        tables.deinit(allocator);
    }
    if (tables.items.len == 0) return error.NoTables;
    try body(&tables.items[0]);
}

test "codegen: model.zig contains @generated and ai-edit-zone" {
    const allocator = std.testing.allocator;
    try withTable(allocator,
        \\CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL);
    , struct {
        fn f(t: *codegen.Table) !void {
            const code = try codegen.generateModel(t.allocator, t, .snake_case);
            defer t.allocator.free(code);
            try std.testing.expect(std.mem.indexOf(u8, code, "// @generated") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "ai-edit-zone") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "UsersModel = zfinal.ModelWithPK") != null);
        }
    }.f);
}

test "codegen: service.zig contains ai-edit-zone: business rules" {
    const allocator = std.testing.allocator;
    try withTable(allocator,
        \\CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT);
    , struct {
        fn f(t: *codegen.Table) !void {
            const code = try codegen.generateService(t.allocator, t);
            defer t.allocator.free(code);
            try std.testing.expect(std.mem.indexOf(u8, code, "ai-edit-zone: business rules") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "pub fn findAll") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "pub fn create") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "pub fn update") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "pub fn deleteOne") != null);
            // v0.9.7: search function for q param
            try std.testing.expect(std.mem.indexOf(u8, code, "pub fn search") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "searchable_columns") != null);
        }
    }.f);
}

test "codegen: search function uses TEXT columns only" {
    const allocator = std.testing.allocator;
    try withTable(allocator,
        \\CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT, age INT, active BOOLEAN);
    , struct {
        fn f(t: *codegen.Table) !void {
            const code = try codegen.generateService(t.allocator, t);
            defer t.allocator.free(code);
            // username is TEXT, so it's searchable
            try std.testing.expect(std.mem.indexOf(u8, code, "\"username\",") != null);
            // age (INT) and active (BOOLEAN) are NOT in searchable list
            try std.testing.expect(std.mem.indexOf(u8, code, "\"age\",") == null);
            try std.testing.expect(std.mem.indexOf(u8, code, "\"active\",") == null);
        }
    }.f);
}

test "codegen: handler.zig contains ai-edit-zone: handler hooks" {
    const allocator = std.testing.allocator;
    try withTable(allocator,
        \\CREATE TABLE comments (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT);
    , struct {
        fn f(t: *codegen.Table) !void {
            const code = try codegen.generateHandler(t.allocator, t, "../");
            defer t.allocator.free(code);
            try std.testing.expect(std.mem.indexOf(u8, code, "ai-edit-zone: handler hooks") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "csrfGuard") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "pub fn list") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "pub fn create") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "pub fn patch") != null);
        }
    }.f);
}

test "codegen: routes.zig registers RESTful endpoints" {
    const allocator = std.testing.allocator;
    try withTable(allocator,
        \\CREATE TABLE products (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT);
    , struct {
        fn f(t: *codegen.Table) !void {
            const code = try codegen.generateRoutes(t.allocator, t);
            defer t.allocator.free(code);
            try std.testing.expect(std.mem.indexOf(u8, code, "app.get") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "app.post") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "app.put") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "app.patch") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "app.delete") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "/:id") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "{id}") == null);
            try std.testing.expect(std.mem.indexOf(u8, code, "@generated by zf routes") != null);
        }
    }.f);
}

test "codegen: actions.zig is smart_routing true source" {
    const allocator = std.testing.allocator;
    try withTable(allocator,
        \\CREATE TABLE products (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT);
    , struct {
        fn f(t: *codegen.Table) !void {
            const code = try codegen.generateActions(t.allocator, t);
            defer t.allocator.free(code);
            try std.testing.expect(std.mem.indexOf(u8, code, "pub const module") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "pub const actions") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, ".name = \"index\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "handler.list") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "ai-edit-zone: extra actions") != null);
        }
    }.f);
}

test "codegen: parseSqlFile extracts columns and types" {
    const allocator = std.testing.allocator;
    var tables = try codegen.parseSqlFile(allocator,
        \\CREATE TABLE foo (id INTEGER PRIMARY KEY, age INT DEFAULT 0, name TEXT NOT NULL);
    );
    defer {
        for (tables.items) |*t| t.deinit();
        tables.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), tables.items.len);
    const t = tables.items[0];
    try std.testing.expectEqualStrings("foo", t.name);
    try std.testing.expect(t.columns.items.len == 3);
    try std.testing.expect(t.columns.items[0].is_primary_key);
    try std.testing.expect(t.columns.items[1].is_nullable); // has DEFAULT 0
    try std.testing.expect(!t.columns.items[2].is_nullable); // NOT NULL
}

test "codegen: generated model contains pascal_name struct" {
    const allocator = std.testing.allocator;
    try withTable(allocator,
        \\CREATE TABLE blog_posts (id INTEGER PRIMARY KEY, title TEXT);
    , struct {
        fn f(t: *codegen.Table) !void {
            const code = try codegen.generateModel(t.allocator, t, .snake_case);
            defer t.allocator.free(code);
            try std.testing.expect(std.mem.indexOf(u8, code, "BlogPosts") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "title:") != null);
        }
    }.f);
}

// ============================================================
// admin_templates tests (vben-style admin UI)
// ============================================================

const admin_templates = @import("admin_templates");

test "admin_templates: renderAll emits 4 files with vben colors" {
    const allocator = std.testing.allocator;
    var tables = try codegen.parseSqlFile(allocator,
        \\CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL);
    );
    defer {
        for (tables.items) |*t| t.deinit();
        tables.deinit(allocator);
    }
    const table = tables.items[0];

    const files = try admin_templates.renderAll(allocator, &[_]*const codegen.Table{&table}, &table);
    defer files.deinit(allocator);

    // vben blue + dark sidebar in full page (list = full page now)
    try std.testing.expect(std.mem.indexOf(u8, files.list, "#2b85e4") != null);
    try std.testing.expect(std.mem.indexOf(u8, files.list, "#001529") != null);

    // ai-edit-zones in all files
    try std.testing.expect(std.mem.indexOf(u8, files.list, "ai-edit-zone: topbar") != null);
    try std.testing.expect(std.mem.indexOf(u8, files.list, "ai-edit-zone: sidebar") != null);
    try std.testing.expect(std.mem.indexOf(u8, files.list, "ai-edit-zone: list filters") != null);
    try std.testing.expect(std.mem.indexOf(u8, files.form, "ai-edit-zone: form fields") != null);
}

test "admin_templates: list has Alpine search, table, pagination, modal" {
    const allocator = std.testing.allocator;
    var tables = try codegen.parseSqlFile(allocator,
        \\CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, body TEXT);
    );
    defer {
        for (tables.items) |*t| t.deinit();
        tables.deinit(allocator);
    }
    const table = tables.items[0];

    const files = try admin_templates.renderAll(allocator, &[_]*const codegen.Table{&table}, &table);
    defer files.deinit(allocator);

    // Alpine search bar
    try std.testing.expect(std.mem.indexOf(u8, files.list, "x-model=\"q\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, files.list, "搜索 Posts") != null);
    try std.testing.expect(std.mem.indexOf(u8, files.list, "新增 Posts") != null);
    // Alpine loadRows function with fetch to /posts/list
    try std.testing.expect(std.mem.indexOf(u8, files.list, "loadRows()") != null);
    try std.testing.expect(std.mem.indexOf(u8, files.list, "/posts/list") != null);
    // Pagination
    try std.testing.expect(std.mem.indexOf(u8, files.list, "共") != null);
    // Modal
    try std.testing.expect(std.mem.indexOf(u8, files.list, "hx-get=\"/posts/form/new\"") != null);
}

test "admin_templates: form has all fields, save button" {
    const allocator = std.testing.allocator;
    var tables = try codegen.parseSqlFile(allocator,
        \\CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, sku TEXT, name TEXT NOT NULL, count INT, active BOOLEAN);
    );
    defer {
        for (tables.items) |*t| t.deinit();
        tables.deinit(allocator);
    }
    const table = tables.items[0];

    const files = try admin_templates.renderAll(allocator, &[_]*const codegen.Table{&table}, &table);
    defer files.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, files.form, "name=\"sku\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, files.form, "name=\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, files.form, "type=\"number\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, files.form, "type=\"checkbox\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, files.form, "保存") != null);
}

test "admin_templates: row has edit + delete actions" {
    const allocator = std.testing.allocator;
    var tables = try codegen.parseSqlFile(allocator,
        \\CREATE TABLE todos (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT);
    );
    defer {
        for (tables.items) |*t| t.deinit();
        tables.deinit(allocator);
    }
    const table = tables.items[0];

    const files = try admin_templates.renderAll(allocator, &[_]*const codegen.Table{&table}, &table);
    defer files.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, files.row, "hx-delete") != null);
    try std.testing.expect(std.mem.indexOf(u8, files.row, "编辑") != null);
    try std.testing.expect(std.mem.indexOf(u8, files.row, "删除") != null);
}

test "admin_templates: multi-table sidebar lists all tables with active highlight" {
    const allocator = std.testing.allocator;
    var tables = try codegen.parseSqlFile(allocator,
        \\CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);
        \\CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT);
        \\CREATE TABLE comments (id INTEGER PRIMARY KEY, body TEXT);
    );
    defer {
        for (tables.items) |*t| t.deinit();
        tables.deinit(allocator);
    }
    var ptrs: [3]*const codegen.Table = undefined;
    for (tables.items, 0..) |*t, i| ptrs[i] = t;

    // Render posts page — current = posts
    const files = try admin_templates.renderAll(allocator, &ptrs, &tables.items[1]);
    defer files.deinit(allocator);

    // All three table labels in sidebar
    try std.testing.expect(std.mem.indexOf(u8, files.list, ">Users<") != null);
    try std.testing.expect(std.mem.indexOf(u8, files.list, ">Posts<") != null);
    try std.testing.expect(std.mem.indexOf(u8, files.list, ">Comments<") != null);
    // 3 sidebar hrefs to /<table>
    var href_count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, files.list, i, "href=\"/")) |pos| {
        if (std.mem.startsWith(u8, files.list[pos..][7..], "users") or
            std.mem.startsWith(u8, files.list[pos..][7..], "posts") or
            std.mem.startsWith(u8, files.list[pos..][7..], "comments"))
        {
            href_count += 1;
        }
        i = pos + 1;
    } else {
        try std.testing.expectEqual(@as(usize, 3), href_count);
    }
    // Active table (Posts) is highlighted with border-l-2 border-vben-primary
    // The active link's class attribute contains the highlight classes
    try std.testing.expect(std.mem.indexOf(u8, files.list, "border-l-2 border-vben-primary") != null);
}

// ─────────────────────────────────────────────────────────────────────────────
// REGRESSION: ensure generated code is syntactically valid Zig
// Uses std.zig.Tokenizer to confirm no tokenization errors.
// Run as part of `zig build test-zf` to catch template regressions early.
// ─────────────────────────────────────────────────────────────────────────────

test "codegen regression: model.zig tokenizes without error" {
    const allocator = std.testing.allocator;
    try withTable(allocator,
        \\CREATE TABLE users (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  name TEXT NOT NULL,
        \\  email TEXT,
        \\  age INTEGER DEFAULT 0,
        \\  created_at DATETIME
        \\);
    , struct {
        fn f(t: *codegen.Table) !void {
            const code = try codegen.generateModel(t.allocator, t, .snake_case);
            defer t.allocator.free(code);
            try expectZigSyntax(code);
        }
    }.f);
}

test "codegen regression: service.zig tokenizes without error" {
    const allocator = std.testing.allocator;
    try withTable(allocator,
        \\CREATE TABLE products (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  sku TEXT NOT NULL,
        \\  price REAL,
        \\  stock INT DEFAULT 0
        \\);
    , struct {
        fn f(t: *codegen.Table) !void {
            const code = try codegen.generateService(t.allocator, t);
            defer t.allocator.free(code);
            try expectZigSyntax(code);
        }
    }.f);
}

test "codegen regression: handler.zig tokenizes without error" {
    const allocator = std.testing.allocator;
    try withTable(allocator,
        \\CREATE TABLE orders (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  customer TEXT NOT NULL,
        \\  total REAL NOT NULL
        \\);
    , struct {
        fn f(t: *codegen.Table) !void {
            const code = try codegen.generateHandler(t.allocator, t, "");
            defer t.allocator.free(code);
            try expectZigSyntax(code);
        }
    }.f);
}

test "codegen regression: routes.zig tokenizes without error" {
    const allocator = std.testing.allocator;
    try withTable(allocator,
        \\CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT);
    , struct {
        fn f(t: *codegen.Table) !void {
            const code = try codegen.generateRoutes(t.allocator, t);
            defer t.allocator.free(code);
            try expectZigSyntax(code);
        }
    }.f);
}

test "codegen regression: all templates tokenize across 6 schemas (incl. annotated)" {
    const allocator = std.testing.allocator;
    const schemas = [_][]const u8{
        \\CREATE TABLE simple (id INTEGER PRIMARY KEY, x TEXT);
        \\CREATE TABLE with_nullable (id INTEGER PRIMARY KEY, x TEXT, y INT NULL);
        \\CREATE TABLE with_defaults (
        \\  id INTEGER PRIMARY KEY,
        \\  status TEXT DEFAULT 'active',
        \\  count INT DEFAULT 0
        \\);
        \\CREATE TABLE unicode_name (id INTEGER PRIMARY KEY, name TEXT, "中文" TEXT);
        \\CREATE TABLE many_cols (
        \\  id INTEGER PRIMARY KEY, a INT, b INT, c INT, d INT, e INT,
        \\  f INT, g INT, h INT, i INT, j INT, k INT
        \\);
        \\CREATE TABLE annotated_posts (
        \\  id INTEGER PRIMARY KEY,
        \\  title TEXT,
        \\  status TEXT,      -- @filter @in_list
        \\  views INT,        -- @filter @sortable
        \\  content TEXT,     -- @search
        \\  secret TEXT       /* @hidden */
        \\);
        \\CREATE TABLE validated_products (
        \\  id INTEGER PRIMARY KEY,
        \\  sku TEXT NOT NULL,     -- @required @unique
        \\  price REAL NOT NULL,   -- @min(0) @max(10000)
        \\  email TEXT             -- @email
        \\);
    };
    for (schemas) |sql| {
        var tables = try codegen.parseSqlFile(allocator, sql);
        defer {
            for (tables.items) |*t| t.deinit();
            tables.deinit(allocator);
        }
        if (tables.items.len == 0) continue;
        const t = &tables.items[0];

        const model = try codegen.generateModel(t.allocator, t, .snake_case);
        defer t.allocator.free(model);
        try expectZigSyntax(model);

        const service = try codegen.generateService(t.allocator, t);
        defer t.allocator.free(service);
        try expectZigSyntax(service);

        const handler = try codegen.generateHandler(t.allocator, t, "");
        defer t.allocator.free(handler);
        try expectZigSyntax(handler);

        const routes = try codegen.generateRoutes(t.allocator, t);
        defer t.allocator.free(routes);
        try expectZigSyntax(routes);
    }
}

/// Tokenize `code` and fail the test if any token reports an error.
/// This catches template regressions where new code is malformed (unbalanced
/// braces, missing semicolons, invalid identifiers, etc.) before users hit
/// a compile error.
fn expectZigSyntax(code: []const u8) !void {
    const allocator = std.testing.allocator;
    const buf = try allocator.allocSentinel(u8, code.len, 0);
    defer allocator.free(buf);
    @memcpy(buf, code);

    var tokenizer: std.zig.Tokenizer = .init(buf);
    var saw_error = false;
    var saw_eof = false;
    while (true) {
        const tok = tokenizer.next();
        if (tok.tag == .invalid) saw_error = true;
        if (tok.tag == .eof) {
            saw_eof = true;
            break;
        }
    }
    if (saw_error) return error.GeneratedCodeHasInvalidTokens;
    if (!saw_eof) return error.GeneratedCodeMissingEof;
}

test "zent_codegen: parse DSL and emit ai-edit-zones" {
    const allocator = std.testing.allocator;
    const dsl =
        \\module shop
        \\api_prefix /api/v1
        \\
        \\entity User {
        \\  name: string
        \\  handle: string @index
        \\}
        \\
        \\entity Product {
        \\  seller_id: int
        \\  name: string
        \\  price_cents: int
        \\  stock: int = 0
        \\  list_by: seller_id
        \\}
    ;
    var schema = try zent_codegen.parseZentDsl(allocator, dsl);
    defer schema.deinit();
    try std.testing.expectEqualStrings("shop", schema.module);
    try std.testing.expectEqual(@as(usize, 2), schema.entities.items.len);
    try std.testing.expect(schema.entities.items[0].fields.items[1].indexed);
    try std.testing.expectEqualStrings("0", schema.entities.items[1].fields.items[3].default_value.?);
    try std.testing.expectEqualStrings("seller_id", schema.entities.items[1].list_by.?);

    const model = try zent_codegen.generateModel(allocator, &schema);
    defer allocator.free(model);
    try std.testing.expect(std.mem.indexOf(u8, model, "// @generated") != null);
    try std.testing.expect(std.mem.indexOf(u8, model, "ai-edit-zone: model hooks") != null);
    try std.testing.expect(std.mem.indexOf(u8, model, "Schema(\"User\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, model, "field.String(\"handle\")") != null);
    try expectZigSyntax(model);

    const persist = try zent_codegen.generatePersistence(allocator, &schema);
    defer allocator.free(persist);
    try std.testing.expect(std.mem.indexOf(u8, persist, "ShopStore") != null);
    try std.testing.expect(std.mem.indexOf(u8, persist, "listProductBySellerId") != null);
    try std.testing.expect(std.mem.indexOf(u8, persist, "ai-edit-zone: custom queries") != null);
    try expectZigSyntax(persist);

    const service = try zent_codegen.generateService(allocator, &schema);
    defer allocator.free(service);
    try std.testing.expect(std.mem.indexOf(u8, service, "ai-edit-zone: business rules") != null);
    try std.testing.expect(std.mem.indexOf(u8, service, "createProduct") != null);
    try expectZigSyntax(service);

    const handler = try zent_codegen.generateHandler(allocator, &schema);
    defer allocator.free(handler);
    try std.testing.expect(std.mem.indexOf(u8, handler, "ai-edit-zone: handler hooks") != null);
    try std.testing.expect(std.mem.indexOf(u8, handler, "pub fn createProduct") != null);
    try std.testing.expect(std.mem.indexOf(u8, handler, "pub fn listProduct") != null);
    try expectZigSyntax(handler);

    const routes = try zent_codegen.generateRoutes(allocator, &schema);
    defer allocator.free(routes);
    try std.testing.expect(std.mem.indexOf(u8, routes, "app.post(") != null);
    try std.testing.expect(std.mem.indexOf(u8, routes, "app.get(") != null);
    try std.testing.expect(std.mem.indexOf(u8, routes, "/products") != null);
    try std.testing.expect(std.mem.indexOf(u8, routes, "@generated by zf routes") != null);
    try expectZigSyntax(routes);

    const actions = try zent_codegen.generateActions(allocator, &schema);
    defer allocator.free(actions);
    try std.testing.expect(std.mem.indexOf(u8, actions, "pub const actions") != null);
    try std.testing.expect(std.mem.indexOf(u8, actions, "action_key") != null);
    try expectZigSyntax(actions);

    const manifest = try zent_codegen.emitJsonManifest(allocator, "schema.zent", &schema);
    defer allocator.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"generator\": \"zf crud:zent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"data_layer\": \"zent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"ai_primary\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "actions.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"purpose\":") != null);
    const fw_ver = @import("zfinal_version");
    try std.testing.expect(std.mem.indexOf(u8, manifest, fw_ver.semver) != null);
}

test "zent_codegen: parse JSON schema" {
    const allocator = std.testing.allocator;
    const js =
        \\{"module":"catalog","entities":[{"name":"Item","fields":[{"name":"title","type":"string"}],"list_by":null}]}
    ;
    var schema = try zent_codegen.parseZentJson(allocator, js);
    defer schema.deinit();
    try std.testing.expectEqualStrings("catalog", schema.module);
    try std.testing.expectEqual(@as(usize, 1), schema.entities.items.len);
}

// ============================================================
// openapi — minimal OpenAPI 3.0.3 spec generator from Zig source
// ============================================================

const openapi = @import("openapi");

test "openapi: parse direct routes" {
    const allocator = std.testing.allocator;
    const src =
        \\const zfinal = @import("zfinal");
        \\
        \\pub fn register(app: *zfinal.ZFinal) !void {
        \\    try app.get("/health", health);
        \\    try app.post("/users", create);
        \\    try app.put("/users/:id", update);
        \\    try app.delete("/users/:id", delete);
        \\    try app.patch("/users/:id", patch);
        \\}
    ;
    var spec = try openapi.parse(allocator, src);
    defer spec.deinit();

    try std.testing.expectEqual(@as(usize, 5), spec.routes.items.len);
    // Sorted by (path, declaration order of HttpMethod: GET<POST<PUT<PATCH<DELETE).
    // /health < /users → /health first.
    try std.testing.expectEqualStrings("/health", spec.routes.items[0].path);
    try std.testing.expectEqual(openapi.HttpMethod.GET, spec.routes.items[0].method);
    try std.testing.expectEqualStrings("/users", spec.routes.items[1].path);
    try std.testing.expectEqual(openapi.HttpMethod.POST, spec.routes.items[1].method);
    // /users/{id} holds PUT(2), PATCH(3), DELETE(4) → sorted by declaration order.
    try std.testing.expectEqualStrings("/users/{id}", spec.routes.items[2].path);
    try std.testing.expectEqual(openapi.HttpMethod.PUT, spec.routes.items[2].method);
    try std.testing.expectEqualStrings("/users/{id}", spec.routes.items[3].path);
    try std.testing.expectEqual(openapi.HttpMethod.PATCH, spec.routes.items[3].method);
    try std.testing.expectEqualStrings("/users/{id}", spec.routes.items[4].path);
    try std.testing.expectEqual(openapi.HttpMethod.DELETE, spec.routes.items[4].method);
}

test "openapi: parse WithInterceptors variants" {
    const allocator = std.testing.allocator;
    const src =
        \\pub fn register(app: *zfinal.ZFinal) !void {
        \\    try app.getWithInterceptors("/me", me, &.{auth});
        \\    try app.postWithInterceptors("/submit", submit, &.{csrf});
        \\    try app.putWithInterceptors("/users/:id", upd, &.{log});
        \\    try app.patchWithInterceptors("/users/:id", pat, &.{log});
        \\    try app.deleteWithInterceptors("/users/:id", del, &.{log});
        \\}
    ;
    var spec = try openapi.parse(allocator, src);
    defer spec.deinit();

    try std.testing.expectEqual(@as(usize, 5), spec.routes.items.len);
    // /me → GET only
    try std.testing.expectEqualStrings("/me", spec.routes.items[0].path);
    try std.testing.expectEqual(openapi.HttpMethod.GET, spec.routes.items[0].method);
    // /submit → POST only
    try std.testing.expectEqualStrings("/submit", spec.routes.items[1].path);
    try std.testing.expectEqual(openapi.HttpMethod.POST, spec.routes.items[1].method);
    // /users/{id} → PUT(2), PATCH(3), DELETE(4) declaration order
    try std.testing.expectEqualStrings("/users/{id}", spec.routes.items[2].path);
    try std.testing.expectEqual(openapi.HttpMethod.PUT, spec.routes.items[2].method);
    try std.testing.expectEqualStrings("/users/{id}", spec.routes.items[3].path);
    try std.testing.expectEqual(openapi.HttpMethod.PATCH, spec.routes.items[3].method);
    try std.testing.expectEqualStrings("/users/{id}", spec.routes.items[4].path);
    try std.testing.expectEqual(openapi.HttpMethod.DELETE, spec.routes.items[4].method);
}

test "openapi: parse RouteGroup prefixes" {
    const allocator = std.testing.allocator;
    const src =
        \\pub fn register(app: *zfinal.ZFinal) !void {
        \\    var api = zfinal.RouteGroup.init(&app, "/api/v1");
        \\    try api.get("/users", list);
        \\    try api.post("/users", create);
        \\    try api.get("/users/:id", show);
        \\}
    ;
    var spec = try openapi.parse(allocator, src);
    defer spec.deinit();

    try std.testing.expectEqual(@as(usize, 3), spec.routes.items.len);
    try std.testing.expectEqualStrings("/api/v1/users", spec.routes.items[0].path);
    try std.testing.expectEqual(openapi.HttpMethod.GET, spec.routes.items[0].method);
    try std.testing.expectEqualStrings("/api/v1/users", spec.routes.items[1].path);
    try std.testing.expectEqual(openapi.HttpMethod.POST, spec.routes.items[1].method);
    try std.testing.expectEqualStrings("/api/v1/users/{id}", spec.routes.items[2].path);
    try std.testing.expectEqual(openapi.HttpMethod.GET, spec.routes.items[2].method);
}

test "openapi: :id is normalized to {id}" {
    const allocator = std.testing.allocator;
    const src =
        \\try app.get("/users/:id/posts/:post_id", h);
    ;
    var spec = try openapi.parse(allocator, src);
    defer spec.deinit();

    try std.testing.expectEqual(@as(usize, 1), spec.routes.items.len);
    try std.testing.expectEqualStrings("/users/{id}/posts/{post_id}", spec.routes.items[0].path);
}

test "openapi: actions.zig action_key" {
    const allocator = std.testing.allocator;
    const src =
        \\.{ .name = "login", .method = .POST, .action_key = "/auth/login", .handler = handler.login },
    ;
    var spec = try openapi.parse(allocator, src);
    defer spec.deinit();
    try std.testing.expectEqual(@as(usize, 1), spec.routes.items.len);
    try std.testing.expectEqual(openapi.HttpMethod.POST, spec.routes.items[0].method);
    try std.testing.expectEqualStrings("/auth/login", spec.routes.items[0].path);
}

test "openapi: dedupes by method+path" {
    const allocator = std.testing.allocator;
    const src =
        \\try app.get("/users", a);
        \\try app.get("/users", b);
        \\try app.post("/users", c);
        \\try app.post("/users", d);
    ;
    var spec = try openapi.parse(allocator, src);
    defer spec.deinit();

    try std.testing.expectEqual(@as(usize, 2), spec.routes.items.len);
    try std.testing.expectEqualStrings("/users", spec.routes.items[0].path);
    try std.testing.expectEqual(openapi.HttpMethod.GET, spec.routes.items[0].method);
    try std.testing.expectEqualStrings("/users", spec.routes.items[1].path);
    try std.testing.expectEqual(openapi.HttpMethod.POST, spec.routes.items[1].method);
}

test "openapi: renderYaml produces minimal OpenAPI 3.0.3" {
    const allocator = std.testing.allocator;
    const src =
        \\pub const User = struct {
        \\    id: i64,
        \\    name: []const u8,
        \\    active: bool,
        \\};
        \\try app.get("/health", h);
        \\try app.get("/users/:id", show);
        \\try app.post("/users", create);
    ;
    var spec = try openapi.parse(allocator, src);
    defer spec.deinit();

    try std.testing.expect(spec.dtos.items.len >= 1);
    try std.testing.expectEqualStrings("User", spec.dtos.items[0].name);

    const yaml = try openapi.renderYaml(allocator, spec);
    defer allocator.free(yaml);

    // Header
    try std.testing.expect(std.mem.indexOf(u8, yaml, "openapi: 3.0.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "title: ZFinal API") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "version: 0.1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "paths:") != null);

    // Paths
    try std.testing.expect(std.mem.indexOf(u8, yaml, "/health:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "/users:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "/users/{id}:") != null);

    // Methods lowercased
    try std.testing.expect(std.mem.indexOf(u8, yaml, "get:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "post:") != null);

    // Parameters + response
    try std.testing.expect(std.mem.indexOf(u8, yaml, "parameters:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "name: id") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "in: path") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "required: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "responses:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "'200':") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "'400':") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "components:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "bearerAuth:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "HttpError:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "JsonObject:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "JsonOk:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "User:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "UserInput:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "$ref: '#/components/schemas/UserInput'") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "requestBody:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "security:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "'401':") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "'404':") != null);
}

test "openapi: YAML output is stable across runs" {
    const allocator = std.testing.allocator;
    const src =
        \\try app.post("/users", create);
        \\try app.get("/users", list);
        \\try app.delete("/users/:id", del);
        \\try app.get("/health", h);
    ;

    var spec1 = try openapi.parse(allocator, src);
    defer spec1.deinit();
    const yaml1 = try openapi.renderYaml(allocator, spec1);
    defer allocator.free(yaml1);

    var spec2 = try openapi.parse(allocator, src);
    defer spec2.deinit();
    const yaml2 = try openapi.renderYaml(allocator, spec2);
    defer allocator.free(yaml2);

    try std.testing.expectEqualStrings(yaml1, yaml2);
}

test "openapi: zent Schema fields become DTOs" {
    const allocator = std.testing.allocator;
    const src =
        \\pub const Product = Schema("Product", .{
        \\    .fields = &.{
        \\        field.Int("seller_id"),
        \\        field.String("name"),
        \\        field.Int("price_cents"),
        \\        field.Bool("active"),
        \\    },
        \\});
        \\try app.get("/products/:id", show);
        \\try app.post("/products", create);
    ;
    var spec = try openapi.parse(allocator, src);
    defer spec.deinit();
    try std.testing.expect(spec.dtos.items.len >= 1);
    var found = false;
    for (spec.dtos.items) |d| {
        if (std.mem.eql(u8, d.name, "Product")) {
            found = true;
            try std.testing.expect(d.fields.len >= 3);
        }
    }
    try std.testing.expect(found);
    const yaml = try openapi.renderYaml(allocator, spec);
    defer allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "Product:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "ProductInput:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "seller_id:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "$ref: '#/components/schemas/ProductInput'") != null);
}

test "openapi: irregular plurals map to singular DTO $ref" {
    const allocator = std.testing.allocator;
    const src =
        \\pub const Category = struct {
        \\    id: i64,
        \\    name: []const u8,
        \\    created_at: i64,
        \\};
        \\try app.get("/categories/:id", show);
        \\try app.post("/categories", create);
    ;
    var spec = try openapi.parse(allocator, src);
    defer spec.deinit();
    try std.testing.expectEqualStrings("Category", spec.dtos.items[0].name);
    try std.testing.expect(spec.dtos.items[0].fields.len >= 2);
    const yaml = try openapi.renderYaml(allocator, spec);
    defer allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "$ref: '#/components/schemas/CategoryInput'") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "$ref: '#/components/schemas/Category'") != null);
    const input_start = std.mem.indexOf(u8, yaml, "\n  CategoryInput:\n").?;
    const input_rest = yaml[input_start..];
    const input_end = std.mem.indexOf(u8, input_rest, "\npaths:") orelse input_rest.len;
    const input_block = input_rest[0..input_end];
    try std.testing.expect(std.mem.indexOf(u8, input_block, "\n    name:") != null);
    try std.testing.expect(std.mem.indexOf(u8, input_block, "\n    id:") == null);
    try std.testing.expect(std.mem.indexOf(u8, input_block, "\n    created_at:") == null);
}

// ── ADR-017: declarative list query — column annotations ─────────────────────

/// Apply `-- @tag` column annotations from `sql` onto the parsed table.
fn annotateTable(allocator: std.mem.Allocator, sql: []const u8, t: *codegen.Table) !void {
    var list = std.ArrayList(codegen.Table).empty;
    defer list.deinit(allocator);
    try list.append(allocator, t.*); // shallow copy — shares column items
    codegen.applyColumnAnnotations(sql, &list);
}

test "codegen: column annotations parsed from CREATE TABLE comments" {
    const allocator = std.testing.allocator;
    try withTable(allocator,
        \\CREATE TABLE posts (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  title TEXT NOT NULL,
        \\  status TEXT,          -- @filter @in_list
        \\  views INTEGER,        -- @filter @sortable
        \\  content TEXT,         -- @search
        \\  secret TEXT           /* @hidden */
        \\);
    , struct {
        fn f(t: *codegen.Table) !void {
            try annotateTable(t.allocator,
                \\CREATE TABLE posts (
                \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
                \\  title TEXT NOT NULL,
                \\  status TEXT,          -- @filter @in_list
                \\  views INTEGER,        -- @filter @sortable
                \\  content TEXT,         -- @search
                \\  secret TEXT           /* @hidden */
                \\);
            , t);
            for (t.columns.items) |*c| {
                if (std.mem.eql(u8, c.name, "status")) {
                    try std.testing.expect(c.filter);
                    try std.testing.expect(!c.hidden);
                }
                if (std.mem.eql(u8, c.name, "views")) {
                    try std.testing.expect(c.filter);
                    try std.testing.expect(c.sortable);
                }
                if (std.mem.eql(u8, c.name, "content")) {
                    try std.testing.expect(c.searchable);
                }
                if (std.mem.eql(u8, c.name, "secret")) {
                    try std.testing.expect(c.hidden);
                }
                if (std.mem.eql(u8, c.name, "title")) {
                    try std.testing.expect(!c.filter);
                    try std.testing.expect(!c.searchable);
                }
            }
        }
    }.f);
}

test "codegen: annotated service emits Filters + Query.list (ADR-017)" {
    const allocator = std.testing.allocator;
    try withTable(allocator,
        \\CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, status TEXT, views INTEGER, content TEXT);
    , struct {
        fn f(t: *codegen.Table) !void {
            try annotateTable(t.allocator,
                \\CREATE TABLE posts (
                \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
                \\  title TEXT,
                \\  status TEXT,        -- @filter @in_list
                \\  views INTEGER,      -- @filter @sortable
                \\  content TEXT        -- @search
                \\);
            , t);
            const code = try codegen.generateService(t.allocator, t);
            defer t.allocator.free(code);
            try std.testing.expect(std.mem.indexOf(u8, code, "pub const Filters = struct") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "status: ?[]const u8 = null") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "views: ?i64 = null") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "sort: ?[]const u8 = null") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "Query.init(db, allocator)") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "try q.textEq(\"status\", f.status)") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "try q.eq(\"views\", f.views)") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "try q.likeAll(&.{\"content\"}, f.q)") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "fn applySort") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "pub fn list(db: *zfinal.DB, f: Filters, page: usize, size: usize, allocator: std.mem.Allocator) !zfinal.Page(Instance)") != null);
        }
    }.f);
}

test "codegen: un-annotated service keeps legacy shape" {
    const allocator = std.testing.allocator;
    try withTable(allocator,
        \\CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT);
    , struct {
        fn f(t: *codegen.Table) !void {
            const code = try codegen.generateService(t.allocator, t);
            defer t.allocator.free(code);
            try std.testing.expect(std.mem.indexOf(u8, code, "pub const Filters") == null);
            try std.testing.expect(std.mem.indexOf(u8, code, "pub fn search") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "searchable_columns") != null);
        }
    }.f);
}

test "codegen: annotated handler uses bindQuery + renderPage (ADR-017)" {
    const allocator = std.testing.allocator;
    try withTable(allocator,
        \\CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, status TEXT);
    , struct {
        fn f(t: *codegen.Table) !void {
            try annotateTable(t.allocator,
                \\CREATE TABLE posts (
                \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
                \\  title TEXT,
                \\  status TEXT   -- @filter
                \\);
            , t);
            const code = try codegen.generateHandler(t.allocator, t, "../");
            defer t.allocator.free(code);
            try std.testing.expect(std.mem.indexOf(u8, code, "ctx.bindQuery(&f)") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "ctx.renderPage(") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "service.list(db, f,") != null);
        }
    }.f);
}

test "codegen: un-annotated handler keeps legacy list" {
    const allocator = std.testing.allocator;
    try withTable(allocator,
        \\CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT);
    , struct {
        fn f(t: *codegen.Table) !void {
            const code = try codegen.generateHandler(t.allocator, t, "../");
            defer t.allocator.free(code);
            try std.testing.expect(std.mem.indexOf(u8, code, "bindQuery") == null);
            try std.testing.expect(std.mem.indexOf(u8, code, "service.search(db, q, ctx.allocator)") != null);
        }
    }.f);
}

test "codegen: validation annotations → validate() rules + validateUnique" {
    const allocator = std.testing.allocator;
    try withTable(allocator,
        \\CREATE TABLE products (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  sku TEXT NOT NULL,        -- @required @unique
        \\  price REAL NOT NULL,      -- @required @min(0) @max(10000)
        \\  email TEXT,               -- @email
        \\  note TEXT
        \\);
    , struct {
        fn f(t: *codegen.Table) !void {
            const model = try codegen.generateModel(t.allocator, t, .snake_case);
            defer t.allocator.free(model);
            try std.testing.expect(std.mem.indexOf(u8, model, "if (data.price < 0) return error.ValidationError;") != null);
            try std.testing.expect(std.mem.indexOf(u8, model, "if (data.price > 10000) return error.ValidationError;") != null);
            try std.testing.expect(std.mem.indexOf(u8, model, "return error.InvalidEmail;") != null);

            const service = try codegen.generateService(t.allocator, t);
            defer t.allocator.free(service);
            try std.testing.expect(std.mem.indexOf(u8, service, "pub fn validateUnique(db: *zfinal.DB, data: Data) !void") != null);
            try std.testing.expect(std.mem.indexOf(u8, service, "error.DuplicateEntry") != null);
            try std.testing.expect(std.mem.indexOf(u8, service, "findWhere(\"sku = ?\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, service, "try validateUnique(db, data);") != null);
            try std.testing.expect(std.mem.indexOf(u8, service, "try validateUnique(db, item.data);") != null);
        }
    }.f);
}

test "codegen: service without @unique emits no-op validateUnique" {
    const allocator = std.testing.allocator;
    try withTable(allocator,
        \\CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT);
    , struct {
        fn f(t: *codegen.Table) !void {
            const code = try codegen.generateService(t.allocator, t);
            defer t.allocator.free(code);
            try std.testing.expect(std.mem.indexOf(u8, code, "pub fn validateUnique(db: *zfinal.DB, data: Data) !void") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "    _ = data;") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "error.DuplicateEntry") == null);
        }
    }.f);
}
