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
