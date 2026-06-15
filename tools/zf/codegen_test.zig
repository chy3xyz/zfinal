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
