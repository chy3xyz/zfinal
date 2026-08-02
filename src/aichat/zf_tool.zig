const std = @import("std");
const fw_version = @import("../version.zig");

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
            \\  "version": "
        );
        try buf.appendSlice(self.allocator, fw_version.semver);
        try buf.appendSlice(self.allocator,
            \\",
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
            try buf.appendSlice(self.allocator, "\n        \"actions\": \"");
            try appendJsonString(self.allocator, &buf, table.name);
            try buf.appendSlice(self.allocator, "/actions.zig\",");
            try buf.appendSlice(self.allocator, "\n        \"routes\": \"");
            try appendJsonString(self.allocator, &buf, table.name);
            try buf.appendSlice(self.allocator, "/routes.zig\"");
            try buf.appendSlice(self.allocator, "\n      },");
            try buf.appendSlice(self.allocator, "\n      \"ai_edit_zones\": [");
            try buf.appendSlice(self.allocator, "\n        { \"file\": \"service.zig\", \"purpose\": \"business rules beyond CRUD\" },");
            try buf.appendSlice(self.allocator, "\n        { \"file\": \"handler.zig\", \"purpose\": \"auth + response shaping\" },");
            try buf.appendSlice(self.allocator, "\n        { \"file\": \"actions.zig\", \"purpose\": \"add custom routes; run zf routes\" }");
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
        const out = try buf.toOwnedSlice(self.allocator);
        for (tables[0..tables_count]) |t| {
            self.allocator.free(t.pascal_name);
        }
        return out;
    }

    /// Parse a `.zent` DSL or zent JSON schema and return the same
    /// machine-readable manifest shape as `zf crud:zent --json`.
    /// Caller owns the returned slice.
    pub fn manifestFromZent(self: ZfTool, schema_src: []const u8) ![]u8 {
        const trimmed = std.mem.trim(u8, schema_src, " \t\n\r");
        if (trimmed.len > 0 and trimmed[0] == '{') {
            return try self.manifestFromZentJson(trimmed);
        }
        return try self.manifestFromZentDsl(trimmed);
    }

    fn manifestFromZentJson(self: ZfTool, src: []const u8) ![]u8 {
        const JsonField = struct {
            name: []const u8,
            type: []const u8,
            index: ?bool = null,
        };
        const JsonEntity = struct {
            name: []const u8,
            fields: []JsonField,
            list_by: ?[]const u8 = null,
        };
        const JsonSchema = struct {
            module: ?[]const u8 = null,
            api_prefix: ?[]const u8 = null,
            entities: []JsonEntity,
        };
        const parsed = try std.json.parseFromSlice(JsonSchema, self.allocator, src, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        return try emitZentManifest(self.allocator, parsed.value.module orelse "app", parsed.value.api_prefix orelse "/api/v1", parsed.value.entities);
    }

    fn manifestFromZentDsl(self: ZfTool, src: []const u8) ![]u8 {
        const JsonField = struct {
            name: []const u8,
            type: []const u8,
            index: ?bool = null,
        };
        const JsonEntity = struct {
            name: []const u8,
            fields: []JsonField,
            list_by: ?[]const u8 = null,
        };

        var module: []const u8 = "app";
        var api_prefix: []const u8 = "/api/v1";
        var entities_buf: [32]JsonEntity = undefined;
        var entities_count: usize = 0;
        var fields_storage: [32][32]JsonField = undefined;
        var field_counts: [32]usize = undefined;
        var list_bys: [32]?[]const u8 = undefined;
        var names: [32][]const u8 = undefined;
        for (&field_counts) |*fc| fc.* = 0;
        for (&list_bys) |*lb| lb.* = null;

        var lines = std.mem.splitScalar(u8, src, '\n');
        var cur: ?usize = null;
        while (lines.next()) |raw| {
            var line = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.indexOf(u8, line, "#")) |h| line = std.mem.trim(u8, line[0..h], " \t");
            if (std.mem.indexOf(u8, line, "//")) |h| line = std.mem.trim(u8, line[0..h], " \t");
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "module ")) {
                module = std.mem.trim(u8, line["module ".len..], " \t\"");
                continue;
            }
            if (std.mem.startsWith(u8, line, "api_prefix ")) {
                api_prefix = std.mem.trim(u8, line["api_prefix ".len..], " \t\"");
                continue;
            }
            if (std.mem.startsWith(u8, line, "entity ")) {
                if (entities_count >= entities_buf.len) break;
                var rest = std.mem.trim(u8, line["entity ".len..], " \t{");
                if (std.mem.indexOfScalar(u8, rest, '{')) |b| rest = std.mem.trim(u8, rest[0..b], " \t");
                names[entities_count] = rest;
                field_counts[entities_count] = 0;
                list_bys[entities_count] = null;
                cur = entities_count;
                entities_count += 1;
                continue;
            }
            if (std.mem.eql(u8, line, "}")) {
                cur = null;
                continue;
            }
            const ci = cur orelse continue;
            if (std.mem.startsWith(u8, line, "list_by:")) {
                list_bys[ci] = std.mem.trim(u8, line["list_by:".len..], " \t");
                continue;
            }
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const fname = std.mem.trim(u8, line[0..colon], " \t");
            const rhs = std.mem.trim(u8, line[colon + 1 ..], " \t");
            var typ: []const u8 = rhs;
            var indexed = false;
            var tok_it = std.mem.tokenizeAny(u8, rhs, " \t");
            if (tok_it.next()) |first| typ = first;
            while (tok_it.next()) |tok| {
                if (std.mem.eql(u8, tok, "@index")) indexed = true;
            }
            if (std.mem.indexOfScalar(u8, typ, '=')) |eq| typ = typ[0..eq];
            if (field_counts[ci] >= fields_storage[ci].len) continue;
            fields_storage[ci][field_counts[ci]] = .{
                .name = fname,
                .type = typ,
                .index = if (indexed) true else null,
            };
            field_counts[ci] += 1;
        }

        for (0..entities_count) |i| {
            entities_buf[i] = .{
                .name = names[i],
                .fields = fields_storage[i][0..field_counts[i]],
                .list_by = list_bys[i],
            };
        }
        return try emitZentManifest(self.allocator, module, api_prefix, entities_buf[0..entities_count]);
    }

    /// System prompt for agents using the zent (schema-as-code) primary stack.
    pub fn buildAgentSystemPromptZent(self: ZfTool, schema_src: []const u8) ![]u8 {
        const manifest = try self.manifestFromZent(schema_src);
        defer self.allocator.free(manifest);

        return std.fmt.allocPrint(self.allocator,
            \\You are an AI development assistant for a ZFinal (Zig) web app
            \\using the **zent** data layer as primary (peer to DB/Model).
            \\
            \\Workflow when the user asks to add a graph / e-commerce / social feature:
            \\1. Write or update `schema.zent` (or JSON). Prefer edges via FK fields + list_by.
            \\2. Run `zf crud:zent schema.zent --json` (or call `ZfTool.manifestFromZent`).
            \\3. Edit ONLY inside `// ── ai-edit-zone: ...` in model/persistence/service/handler.
            \\4. Never mix `zfinal.DB` and `zent` Driver in one transaction.
            \\5. Wire bootstrap (migrateSchema + Store + Service) in main.zig if missing.
            \\6. Verify: zf check && zig build test
            \\
            \\Current zent manifest:
            \\{s}
        , .{manifest});
    }

    /// Unified prompt: picks SQL vs zent based on source shape.
    pub fn buildAgentSystemPrompt(self: ZfTool, sql: []const u8) ![]u8 {
        const manifest = try self.manifestFromSql(sql);
        defer self.allocator.free(manifest);

        return std.fmt.allocPrint(self.allocator,
            \\You are an AI development assistant for a ZFinal (Zig) web app.
            \\
            \\ZFinal has TWO first-class data layers — pick one primary per module:
            \\  A) DB/Model  → `zf crud:sql` / ZfTool.manifestFromSql
            \\  B) zent      → `zf crud:zent` / ZfTool.manifestFromZent  (e-commerce/social)
            \\
            \\When the user asks to add a feature on the SQL stack:
            \\1. Use `ZfTool.manifestFromSql` (or zf crud:sql --json).
            \\2. Edit ONLY inside `// ── ai-edit-zone: ...` blocks.
            \\3. After edits: zf check && zig build test
            \\
            \\For graph-heavy domains, switch to zent (see buildAgentSystemPromptZent).
            \\
            \\Current SQL schema manifest:
            \\{s}
        , .{manifest});
    }
};

fn emitZentManifest(allocator: std.mem.Allocator, module: []const u8, api_prefix: []const u8, entities: anytype) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\{
        \\  "$schema": "https://zfinal.dev/schemas/zent-manifest-1.json",
        \\  "version": "
    );
    try buf.appendSlice(allocator, fw_version.semver);
    try buf.appendSlice(allocator,
        \\",
        \\  "generator": "ZfTool.manifestFromZent",
        \\  "data_layer": "zent",
        \\  "ai_primary": true,
        \\  "module": "
    );
    try appendJsonString(allocator, &buf, module);
    try buf.appendSlice(allocator, "\",\n  \"api_prefix\": \"");
    try appendJsonString(allocator, &buf, api_prefix);
    try buf.appendSlice(allocator, "\",\n  \"files\": {\n");
    try buf.appendSlice(allocator, "    \"model\": \"src/modules/");
    try appendJsonString(allocator, &buf, module);
    try buf.appendSlice(allocator, "/model.zig\",\n    \"persistence\": \"src/modules/");
    try appendJsonString(allocator, &buf, module);
    try buf.appendSlice(allocator, "/persistence.zig\",\n    \"service\": \"src/modules/");
    try appendJsonString(allocator, &buf, module);
    try buf.appendSlice(allocator, "/service.zig\",\n    \"handler\": \"src/modules/");
    try appendJsonString(allocator, &buf, module);
    try buf.appendSlice(allocator, "/handler.zig\",\n    \"routes\": \"src/modules/");
    try appendJsonString(allocator, &buf, module);
    try buf.appendSlice(allocator, "/routes.zig\"\n  },\n");
    try buf.appendSlice(allocator,
        \\  "ai_edit_zones": [
        \\    { "file": "model.zig", "markers": ["// ── ai-edit-zone: model hooks"], "purpose": "edges, privacy, extra Schema" },
        \\    { "file": "persistence.zig", "markers": ["// ── ai-edit-zone: custom queries"], "purpose": "domain queries" },
        \\    { "file": "service.zig", "markers": ["// ── ai-edit-zone: business rules"], "purpose": "validation" },
        \\    { "file": "handler.zig", "markers": ["// ── ai-edit-zone: handler hooks"], "purpose": "auth + response shaping" }
        \\  ],
        \\  "entities": [
    );

    for (entities, 0..) |ent, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "\n    {\n      \"name\": \"");
        try appendJsonString(allocator, &buf, ent.name);
        try buf.appendSlice(allocator, "\"");
        if (ent.list_by) |lb| {
            try buf.appendSlice(allocator, ",\n      \"list_by\": \"");
            try appendJsonString(allocator, &buf, lb);
            try buf.appendSlice(allocator, "\"");
        }
        try buf.appendSlice(allocator, ",\n      \"fields\": [");
        for (ent.fields, 0..) |f, fi| {
            if (fi > 0) try buf.appendSlice(allocator, ",");
            try buf.appendSlice(allocator, "\n        { \"name\": \"");
            try appendJsonString(allocator, &buf, f.name);
            try buf.appendSlice(allocator, "\", \"type\": \"");
            try appendJsonString(allocator, &buf, f.type);
            try buf.appendSlice(allocator, "\"");
            if (f.index orelse false) try buf.appendSlice(allocator, ", \"index\": true");
            try buf.appendSlice(allocator, " }");
        }
        try buf.appendSlice(allocator, "\n      ]\n    }");
    }
    try buf.appendSlice(allocator,
        \\
        \\  ],
        \\  "next_steps": [
        \\    "zf crud:zent <schema> --json then edit ai-edit-zones only",
        \\    "Wire migrateSchema + Store in main.zig",
        \\    "zf check && zig build test"
        \\  ]
        \\}
        \\
    );
    return try buf.toOwnedSlice(allocator);
}

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

test "ZfTool.manifestFromZent: DSL" {
    const allocator = std.testing.allocator;
    const tool = ZfTool.init(allocator);
    const dsl =
        \\module shop
        \\entity Product {
        \\  seller_id: int
        \\  name: string
        \\  list_by: seller_id
        \\}
    ;
    const manifest = try tool.manifestFromZent(dsl);
    defer allocator.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"data_layer\": \"zent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"module\": \"shop\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"name\": \"Product\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "ai-edit-zone: custom queries") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "persistence.zig") != null);
}

test "ZfTool.buildAgentSystemPromptZent mentions zent workflow" {
    const allocator = std.testing.allocator;
    const tool = ZfTool.init(allocator);
    const prompt = try tool.buildAgentSystemPromptZent("module app\nentity User { name: string }\n");
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "zent") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "ai-edit-zone") != null);
}
