const std = @import("std");

/// In-process tool that lets an AI agent invoke the ZFinal code
/// generator without shelling out to the `zf` binary. The same
/// manifest shape as `zf crud:sql --json` so the AI's parsing
/// logic is identical regardless of how it was generated.
pub const ZfTool = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ZfTool {
        return .{ .allocator = allocator };
    }

    /// Parse a SQL schema and return a manifest describing the
    /// tables and AI edit zones — same JSON shape `zf crud:sql --json`
    /// emits. Caller owns the returned slice.
    pub fn manifestFromSql(self: ZfTool, sql: []const u8) ![]u8 {
        const Field = struct {
            name: []const u8,
            sql_type: []const u8,
            nullable: bool,
            primary_key: bool,
        };
        const Table = struct {
            name: []const u8,
            pascal_name: []const u8,
            fields: []const Field,
        };

        var tables: [16]Table = undefined;
        var tables_count: usize = 0;

        // Parse CREATE TABLE statements. Naive but covers 95% of cases.
        var i: usize = 0;
        while (i < sql.len) {
            const start = std.mem.indexOfPos(u8, sql, i, "CREATE TABLE") orelse break;
            const open_paren = std.mem.indexOfScalarPos(u8, sql, start, '(') orelse break;
            const close_paren = findMatchingParen(sql, open_paren) orelse break;
            _ = std.mem.indexOfPos(u8, sql, open_paren, " ");

            // Extract table name between "CREATE TABLE" and "(" (or "IF NOT EXISTS")
            var name_start: usize = start + "CREATE TABLE".len;
            if (std.mem.indexOfPos(u8, sql, name_start, "IF NOT EXISTS")) |n| {
                name_start = n + "IF NOT EXISTS".len;
            }
            while (name_start < open_paren and sql[name_start] == ' ') : (name_start += 1) {}

            const raw_name = std.mem.trim(u8, sql[name_start..open_paren], " \n\t`\"");
            if (tables_count >= tables.len) break;

            // Parse fields
            var fields: [32]Field = undefined;
            var fields_count: usize = 0;
            const body = sql[open_paren + 1 .. close_paren];
            var field_iter = std.mem.splitScalar(u8, body, ',');
            while (field_iter.next()) |raw_field| {
                const field = std.mem.trim(u8, raw_field, " \n\t");
                if (field.len == 0) continue;
                if (std.mem.startsWith(u8, field, "PRIMARY KEY") or
                    std.mem.startsWith(u8, field, "FOREIGN KEY") or
                    std.mem.startsWith(u8, field, "UNIQUE") or
                    std.mem.startsWith(u8, field, "CONSTRAINT") or
                    std.mem.startsWith(u8, field, "INDEX") or
                    std.mem.startsWith(u8, field, "CHECK")) continue;
                if (fields_count >= fields.len) continue;
                const field_name_end = std.mem.indexOfScalar(u8, field, ' ') orelse field.len;
                const fname = field[0..field_name_end];
                const rest = std.mem.trim(u8, field[field_name_end..], " \n\t");
                const type_end = std.mem.indexOfAny(u8, rest, " \n\t(,") orelse rest.len;
                const ftype = rest[0..type_end];
                const is_pk = std.mem.indexOf(u8, rest, "PRIMARY KEY") != null;
                const nullable = std.mem.indexOf(u8, rest, "NOT NULL") == null and !is_pk;
                fields[fields_count] = .{
                    .name = fname,
                    .sql_type = ftype,
                    .nullable = nullable,
                    .primary_key = is_pk,
                };
                fields_count += 1;
            }

            const pascal = try toPascalCase(self.allocator, raw_name);
            tables[tables_count] = .{
                .name = raw_name,
                .pascal_name = pascal,
                .fields = fields[0..fields_count],
            };
            tables_count += 1;
            i = close_paren + 1;
        }

        // Emit JSON manifest
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator,
            \\{
            \\  "$schema": "https://zfinal.dev/schemas/manifest-1.json",
            \\  "version": "0.9.2",
            \\  "generator": "ZfTool.manifestFromSql",
            \\  "tables": [
        );

        for (tables[0..tables_count], 0..) |table, ti| {
            if (ti > 0) try buf.appendSlice(self.allocator, ",");
            try buf.appendSlice(self.allocator, "\n    {");
            try buf.appendSlice(self.allocator, "\n      \"name\": \"");
            try appendJsonString(self.allocator, &buf, table.name);
            try buf.appendSlice(self.allocator, "\",");
            try buf.appendSlice(self.allocator, "\n      \"pascal_name\": \"");
            try appendJsonString(self.allocator, &buf, table.pascal_name);
            try buf.appendSlice(self.allocator, "\",");
            try buf.appendSlice(self.allocator, "\n      \"files\": {");
            try buf.appendSlice(self.allocator, "\n        \"model\": \"");
            try appendJsonString(self.allocator, &buf, table.name);
            try buf.appendSlice(self.allocator, "/model.zig\",");
            try buf.appendSlice(self.allocator, "\n        \"service\": \"");
            try appendJsonString(self.allocator, &buf, table.name);
            try buf.appendSlice(self.allocator, "/service.zig\",");
            try buf.appendSlice(self.allocator, "\n        \"handler\": \"");
            try appendJsonString(self.allocator, &buf, table.name);
            try buf.appendSlice(self.allocator, "/handler.zig\",");
            try buf.appendSlice(self.allocator, "\n        \"routes\": \"");
            try appendJsonString(self.allocator, &buf, table.name);
            try buf.appendSlice(self.allocator, "/routes.zig\"");
            try buf.appendSlice(self.allocator, "\n      },");
            try buf.appendSlice(self.allocator, "\n      \"ai_edit_zones\": [");
            try buf.appendSlice(self.allocator, "\n        { \"file\": \"service.zig\", \"purpose\": \"business rules beyond CRUD\" },");
            try buf.appendSlice(self.allocator, "\n        { \"file\": \"handler.zig\", \"purpose\": \"auth + response shaping\" }");
            try buf.appendSlice(self.allocator, "\n      ],");
            try buf.appendSlice(self.allocator, "\n      \"fields\": [");
            for (table.fields, 0..) |f, fi| {
                if (fi > 0) try buf.appendSlice(self.allocator, ",");
                try buf.appendSlice(self.allocator, "\n        { \"name\": \"");
                try appendJsonString(self.allocator, &buf, f.name);
                try buf.appendSlice(self.allocator, "\", \"sql_type\": \"");
                try appendJsonString(self.allocator, &buf, f.sql_type);
                try buf.appendSlice(self.allocator, "\", \"nullable\": ");
                try buf.appendSlice(self.allocator, if (f.nullable) "true" else "false");
                try buf.appendSlice(self.allocator, ", \"primary_key\": ");
                try buf.appendSlice(self.allocator, if (f.primary_key) "true" else "false");
                try buf.appendSlice(self.allocator, " }");
            }
            try buf.appendSlice(self.allocator, "\n      ]");
            try buf.appendSlice(self.allocator, "\n    }");
        }
        try buf.appendSlice(self.allocator, "\n  ]");
        try buf.appendSlice(self.allocator, "\n}\n");
        return buf.toOwnedSlice(self.allocator);
    }

    /// Build a system prompt for an AI agent that has the `ZfTool`
    /// available. Tells the agent what files would be generated and
    /// where to edit. Returns a slice the caller owns.
    pub fn buildAgentSystemPrompt(self: ZfTool, sql: []const u8) ![]u8 {
        const manifest = try self.manifestFromSql(sql);
        defer self.allocator.free(manifest);

        return std.fmt.allocPrint(self.allocator,
            \\You are an AI development assistant for a ZFinal (Zig) web app.
            \\
            \\When the user asks to add a feature, the workflow is:
            \\1. Use the `ZfTool.manifestFromSql` API to see what code would
            \\   be generated for the project's schema.
            \\2. Edit ONLY inside `// ── ai-edit-zone: ...` blocks in
            \\   generated files. Do not modify generated boilerplate.
            \\3. After edits, recommend: zf check && zig build test
            \\
            \\Current schema manifest (call ZfTool.manifestFromSql again if it changes):
            \\{s}
        , .{manifest});
    }
};

fn findMatchingParen(s: []const u8, open_pos: usize) ?usize {
    var depth: usize = 1;
    var i: usize = open_pos + 1;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn toPascalCase(allocator: std.mem.Allocator, snake: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var capitalize_next = true;
    for (snake) |c| {
        if (c == '_' or c == '-' or c == ' ') {
            capitalize_next = true;
        } else if (capitalize_next) {
            try out.append(allocator, std.ascii.toUpper(c));
            capitalize_next = false;
        } else {
            try out.append(allocator, c);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn appendJsonString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                const ch: [1]u8 = .{c};
                try buf.appendSlice(allocator, &ch);
            },
        }
    }
}

test "ZfTool.manifestFromSql: simple users table" {
    const allocator = std.testing.allocator;
    const tool = ZfTool.init(allocator);
    const sql =
        \\CREATE TABLE users (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    email TEXT UNIQUE NOT NULL,
        \\    age INT DEFAULT 0
        \\);
    ;
    const manifest = try tool.manifestFromSql(sql);
    defer allocator.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"name\": \"users\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"pascal_name\": \"Users\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"name\": \"email\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"nullable\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"primary_key\": true") != null);
}

test "ZfTool.manifestFromSql: multi-table" {
    const allocator = std.testing.allocator;
    const tool = ZfTool.init(allocator);
    const sql =
        \\CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);
        \\CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INT NOT NULL, body TEXT);
    ;
    const manifest = try tool.manifestFromSql(sql);
    defer allocator.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"name\": \"users\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"name\": \"posts\"") != null);
}
