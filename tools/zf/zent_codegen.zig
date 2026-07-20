//! zf crud:zent — generate ZFinal modules for the zent data layer.
//!
//! Input: `.zent` DSL or `.json` schema.
//! Output: `src/modules/<module>/{model,persistence,service,handler,routes}.zig`
//! Parallel to `codegen.zig` (SQL → DB/Model). Do not mix stacks in one Tx.

const std = @import("std");

pub const FieldType = enum {
    string,
    text,
    int,
    bool,
    float,
    time,

    pub fn fromToken(tok: []const u8) ?FieldType {
        if (std.mem.eql(u8, tok, "string") or std.mem.eql(u8, tok, "str")) return .string;
        if (std.mem.eql(u8, tok, "text")) return .text;
        if (std.mem.eql(u8, tok, "int") or std.mem.eql(u8, tok, "i64") or std.mem.eql(u8, tok, "integer")) return .int;
        if (std.mem.eql(u8, tok, "bool") or std.mem.eql(u8, tok, "boolean")) return .bool;
        if (std.mem.eql(u8, tok, "float") or std.mem.eql(u8, tok, "f64") or std.mem.eql(u8, tok, "double")) return .float;
        if (std.mem.eql(u8, tok, "time") or std.mem.eql(u8, tok, "datetime") or std.mem.eql(u8, tok, "timestamp")) return .time;
        return null;
    }

    pub fn zentCtor(self: FieldType) []const u8 {
        return switch (self) {
            .string => "String",
            .text => "Text",
            .int => "Int",
            .bool => "Bool",
            .float => "Float",
            .time => "Time",
        };
    }

    pub fn zigType(self: FieldType) []const u8 {
        return switch (self) {
            .string, .text => "[]const u8",
            .int, .time => "i64",
            .bool => "bool",
            .float => "f64",
        };
    }

    pub fn isOwnedSlice(self: FieldType) bool {
        return self == .string or self == .text;
    }
};

pub const Field = struct {
    name: []const u8,
    typ: FieldType,
    indexed: bool = false,
    default_value: ?[]const u8 = null,

    pub fn deinit(self: *Field, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.default_value) |d| allocator.free(d);
    }
};

pub const Entity = struct {
    name: []const u8,
    fields: std.ArrayList(Field),
    list_by: ?[]const u8 = null,

    pub fn deinit(self: *Entity, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.fields.items) |*f| f.deinit(allocator);
        self.fields.deinit(allocator);
        if (self.list_by) |lb| allocator.free(lb);
    }

    pub fn clientName(self: Entity, buf: []u8) []const u8 {
        if (self.name.len == 0 or self.name.len > buf.len) return "";
        @memcpy(buf[0..self.name.len], self.name);
        buf[0] = std.ascii.toLower(buf[0]);
        return buf[0..self.name.len];
    }
};

pub const Schema = struct {
    allocator: std.mem.Allocator,
    module: []const u8,
    api_prefix: []const u8,
    entities: std.ArrayList(Entity),

    pub fn deinit(self: *Schema) void {
        self.allocator.free(self.module);
        self.allocator.free(self.api_prefix);
        for (self.entities.items) |*e| e.deinit(self.allocator);
        self.entities.deinit(self.allocator);
    }
};

pub fn pascalize(allocator: std.mem.Allocator, snake: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var cap = true;
    for (snake) |c| {
        if (c == '_' or c == '-' or c == '/') {
            cap = true;
            continue;
        }
        try out.append(allocator, if (cap) std.ascii.toUpper(c) else c);
        cap = false;
    }
    return try out.toOwnedSlice(allocator);
}

pub fn pluralize(allocator: std.mem.Allocator, singular: []const u8) ![]u8 {
    if (singular.len == 0) return try allocator.dupe(u8, "items");
    if (std.mem.endsWith(u8, singular, "s") or std.mem.endsWith(u8, singular, "x") or
        std.mem.endsWith(u8, singular, "ch") or std.mem.endsWith(u8, singular, "sh"))
    {
        return try std.fmt.allocPrint(allocator, "{s}es", .{singular});
    }
    if (singular.len >= 2 and singular[singular.len - 1] == 'y') {
        const prev = singular[singular.len - 2];
        if (prev != 'a' and prev != 'e' and prev != 'i' and prev != 'o' and prev != 'u') {
            return try std.fmt.allocPrint(allocator, "{s}ies", .{singular[0 .. singular.len - 1]});
        }
    }
    return try std.fmt.allocPrint(allocator, "{s}s", .{singular});
}

fn trimComment(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, "#")) |i| return std.mem.trim(u8, line[0..i], " \t");
    if (std.mem.indexOf(u8, line, "//")) |i| return std.mem.trim(u8, line[0..i], " \t");
    return line;
}

pub fn parseZentDsl(allocator: std.mem.Allocator, src: []const u8) !Schema {
    var schema = Schema{
        .allocator = allocator,
        .module = try allocator.dupe(u8, "app"),
        .api_prefix = try allocator.dupe(u8, "/api/v1"),
        .entities = .empty,
    };
    errdefer schema.deinit();

    var lines = std.mem.splitScalar(u8, src, '\n');
    var current: ?*Entity = null;

    while (lines.next()) |raw| {
        const line = trimComment(std.mem.trim(u8, raw, " \t\r"));
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "module ")) {
            allocator.free(schema.module);
            schema.module = try allocator.dupe(u8, std.mem.trim(u8, line["module ".len..], " \t\""));
            continue;
        }
        if (std.mem.startsWith(u8, line, "api_prefix ")) {
            allocator.free(schema.api_prefix);
            schema.api_prefix = try allocator.dupe(u8, std.mem.trim(u8, line["api_prefix ".len..], " \t\""));
            continue;
        }
        if (std.mem.startsWith(u8, line, "entity ")) {
            var rest = std.mem.trim(u8, line["entity ".len..], " \t{");
            if (std.mem.indexOfScalar(u8, rest, '{')) |brace| {
                rest = std.mem.trim(u8, rest[0..brace], " \t");
            }
            try schema.entities.append(allocator, .{
                .name = try allocator.dupe(u8, rest),
                .fields = .empty,
            });
            current = &schema.entities.items[schema.entities.items.len - 1];
            continue;
        }
        if (std.mem.eql(u8, line, "}")) {
            current = null;
            continue;
        }
        if (current == null) continue;

        if (std.mem.startsWith(u8, line, "list_by:")) {
            const v = std.mem.trim(u8, line["list_by:".len..], " \t");
            if (current.?.list_by) |old| allocator.free(old);
            current.?.list_by = try allocator.dupe(u8, v);
            continue;
        }

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidFieldLine;
        const fname = std.mem.trim(u8, line[0..colon], " \t");
        const rhs = std.mem.trim(u8, line[colon + 1 ..], " \t");

        var indexed = false;
        var default_value: ?[]const u8 = null;
        var type_tok: []const u8 = rhs;

        // tokens: type [@index] [= default]
        var tok_it = std.mem.tokenizeAny(u8, rhs, " \t");
        const first = tok_it.next() orelse return error.InvalidFieldLine;
        type_tok = first;
        while (tok_it.next()) |tok| {
            if (std.mem.eql(u8, tok, "@index")) {
                indexed = true;
            } else if (std.mem.eql(u8, tok, "=")) {
                if (tok_it.next()) |dv| {
                    default_value = try allocator.dupe(u8, std.mem.trim(u8, dv, "\"'"));
                }
            } else if (tok[0] == '=') {
                default_value = try allocator.dupe(u8, std.mem.trim(u8, tok[1..], "\"'"));
            }
        }

        // also support "int=0" stuck together after type
        if (std.mem.indexOfScalar(u8, type_tok, '=')) |eq| {
            if (default_value == null) {
                default_value = try allocator.dupe(u8, std.mem.trim(u8, type_tok[eq + 1 ..], "\"'"));
            }
            type_tok = type_tok[0..eq];
        }

        const typ = FieldType.fromToken(type_tok) orelse return error.UnknownFieldType;
        try current.?.fields.append(allocator, .{
            .name = try allocator.dupe(u8, fname),
            .typ = typ,
            .indexed = indexed,
            .default_value = default_value,
        });
    }

    if (schema.entities.items.len == 0) return error.NoEntities;
    return schema;
}

const JsonField = struct {
    name: []const u8,
    @"type": []const u8,
    index: ?bool = null,
    default: ?[]const u8 = null,
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

pub fn parseZentJson(allocator: std.mem.Allocator, src: []const u8) !Schema {
    const parsed = try std.json.parseFromSlice(JsonSchema, allocator, src, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const j = parsed.value;

    var schema = Schema{
        .allocator = allocator,
        .module = try allocator.dupe(u8, j.module orelse "app"),
        .api_prefix = try allocator.dupe(u8, j.api_prefix orelse "/api/v1"),
        .entities = .empty,
    };
    errdefer schema.deinit();

    for (j.entities) |je| {
        var ent = Entity{
            .name = try allocator.dupe(u8, je.name),
            .fields = .empty,
            .list_by = if (je.list_by) |lb| try allocator.dupe(u8, lb) else null,
        };
        for (je.fields) |jf| {
            const typ = FieldType.fromToken(jf.@"type") orelse return error.UnknownFieldType;
            try ent.fields.append(allocator, .{
                .name = try allocator.dupe(u8, jf.name),
                .typ = typ,
                .indexed = jf.index orelse false,
                .default_value = if (jf.default) |d| try allocator.dupe(u8, d) else null,
            });
        }
        try schema.entities.append(allocator, ent);
    }
    if (schema.entities.items.len == 0) return error.NoEntities;
    return schema;
}

pub fn parseFile(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !Schema {
    if (std.mem.endsWith(u8, path, ".json")) return try parseZentJson(allocator, content);
    return try parseZentDsl(allocator, content);
}

pub fn generateModel(allocator: std.mem.Allocator, schema: *const Schema) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll(
        \\// @generated by `zf crud:zent` — AI: edit inside ai-edit-zone only.
        \\// Regenerate: zf crud:zent <schema.zent|schema.json> [--force]
        \\//! Domain schema (zent Schema-as-code). Primary data layer = zfinal.zent.
        \\
        \\const zent = @import("zfinal").zent;
        \\const field = zent.core.field;
        \\const Schema = zent.core.schema.Schema;
        \\
    );

    for (schema.entities.items) |ent| {
        try w.print("\npub const {s} = Schema(\"{s}\", .{{\n", .{ ent.name, ent.name });
        try w.writeAll("    .fields = &.{\n");
        for (ent.fields.items) |f| {
            try w.print("        field.{s}(\"{s}\")", .{ f.typ.zentCtor(), f.name });
            if (f.default_value) |dv| try w.print(".Default(\"{s}\")", .{dv});
            try w.writeAll(",\n");
        }
        try w.writeAll("    },\n");
        var any_index = false;
        for (ent.fields.items) |f| {
            if (f.indexed) {
                any_index = true;
                break;
            }
        }
        if (any_index) {
            try w.writeAll("    .indexes = &.{\n");
            for (ent.fields.items) |f| {
                if (!f.indexed) continue;
                try w.print("        zent.core.index.Fields(&.{{\"{s}\"}}),\n", .{f.name});
            }
            try w.writeAll("    },\n");
        }
        try w.writeAll("});\n");
    }

    try w.writeAll(
        \\
        \\// ── ai-edit-zone: model hooks ─────────────────────────────────────
        \\// Add edges, privacy rules, or extra Schema decls here.
        \\// ── end ai-edit-zone ──────────────────────────────────────────────
        \\
    );
    return try aw.toOwnedSlice();
}

pub fn generatePersistence(allocator: std.mem.Allocator, schema: *const Schema) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    const mod_pascal = try pascalize(allocator, schema.module);
    defer allocator.free(mod_pascal);
    const store_name = try std.fmt.allocPrint(allocator, "{s}Store", .{mod_pascal});
    defer allocator.free(store_name);

    try w.writeAll(
        \\// @generated by `zf crud:zent` — AI: edit inside ai-edit-zone only.
        \\//! Persistence over zent Client — SQL stays inside zent builders.
        \\const std = @import("std");
        \\const zent = @import("zfinal").zent;
        \\const model = @import("model.zig");
        \\
        \\const graph = zent.codegen.graph.buildGraph(&.{ 
    );
    for (schema.entities.items, 0..) |ent, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("model.{s}", .{ent.name});
    }
    try w.writeAll(
        \\ });
        \\pub const infos = graph.types;
        \\pub const Client = zent.codegen.client.Client(infos);
        \\
    );
    for (schema.entities.items, 0..) |ent, i| {
        try w.print("const {s}Info = infos[{d}];\n", .{ ent.name, i });
    }

    try w.print("\npub const {s} = struct {{\n", .{store_name});
    try w.writeAll(
        \\    allocator: std.mem.Allocator,
        \\    client: Client,
        \\
        \\    pub fn init(allocator: std.mem.Allocator, driver: zent.sql_driver.Driver) @This() {
        \\        return .{
        \\            .allocator = allocator,
        \\            .client = zent.codegen.client.makeClient(infos, allocator, driver),
        \\        };
        \\    }
        \\
    );

    var name_buf: [128]u8 = undefined;
    for (schema.entities.items) |ent| {
        const cname = ent.clientName(&name_buf);

        try w.print("    pub fn create{s}(self: *@This()", .{ent.name});
        for (ent.fields.items) |f| {
            try w.print(", {s}: {s}", .{ f.name, f.typ.zigType() });
        }
        try w.writeAll(") !i64 {\n");
        try w.print("        var b = try self.client.{s}.Create();\n", .{cname});
        try w.writeAll("        defer b.deinit();\n");
        for (ent.fields.items) |f| {
            try w.print("        _ = try b.setFieldValue(\"{s}\", {s});\n", .{ f.name, f.name });
        }
        try w.writeAll("        const row = try b.Save();\n        return row.id;\n    }\n\n");

        if (ent.list_by) |lb| {
            const lb_pascal = try pascalize(allocator, lb);
            defer allocator.free(lb_pascal);

            try w.print("    pub const {s}Row = struct {{\n", .{ent.name});
            try w.writeAll("        id: i64,\n");
            for (ent.fields.items) |f| {
                try w.print("        {s}: {s},\n", .{ f.name, f.typ.zigType() });
            }
            try w.writeAll("    };\n\n");

            try w.print("    pub fn list{s}By{s}(self: *@This(), {s}: i64) ![]{s}Row {{\n", .{
                ent.name, lb_pascal, lb, ent.name,
            });
            try w.print("        var q = self.client.{s}.Query();\n", .{cname});
            try w.writeAll("        defer q.deinit();\n");
            try w.print("        const preds = self.client.{s}.predicates;\n", .{cname});
            try w.print("        _ = try q.Where(.{{preds.{s}EQ(.{{ .int = {s} }})}});\n", .{ lb, lb });
            try w.writeAll("        var found = try q.All();\n");
            try w.writeAll("        defer {\n            for (found.items) |*p| {\n");
            try w.print("                zent.codegen.deinitEntity(infos, {s}Info, p, self.allocator);\n", .{ent.name});
            try w.writeAll("            }\n            found.deinit();\n        }\n\n");
            try w.print("        var out = try self.allocator.alloc({s}Row, found.items.len);\n", .{ent.name});
            try w.writeAll("        errdefer self.allocator.free(out);\n");
            try w.writeAll("        for (found.items, 0..) |p, i| {\n            out[i] = .{\n                .id = p.id,\n");
            for (ent.fields.items) |f| {
                if (f.typ.isOwnedSlice()) {
                    try w.print("                .{s} = try self.allocator.dupe(u8, p.{s}),\n", .{ f.name, f.name });
                } else {
                    try w.print("                .{s} = p.{s},\n", .{ f.name, f.name });
                }
            }
            try w.writeAll("            };\n        }\n        return out;\n    }\n\n");

            try w.print("    pub fn free{s}s(self: *@This(), rows: []{s}Row) void {{\n", .{ ent.name, ent.name });
            try w.writeAll("        for (rows) |r| {\n");
            for (ent.fields.items) |f| {
                if (f.typ.isOwnedSlice()) {
                    try w.print("            self.allocator.free(r.{s});\n", .{f.name});
                }
            }
            try w.writeAll("        }\n        self.allocator.free(rows);\n    }\n\n");
        }
    }

    try w.writeAll(
        \\    // ── ai-edit-zone: custom queries ───────────────────────────────
        \\    // ── end ai-edit-zone ──────────────────────────────────────────
        \\
        \\    comptime {
    );
    for (schema.entities.items) |ent| {
        if (ent.list_by == null) {
            try w.print("        _ = {s}Info;\n", .{ent.name});
        }
    }
    try w.writeAll("    }\n};\n");
    return try aw.toOwnedSlice();
}

pub fn generateService(allocator: std.mem.Allocator, schema: *const Schema) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    const mod_pascal = try pascalize(allocator, schema.module);
    defer allocator.free(mod_pascal);
    const store_name = try std.fmt.allocPrint(allocator, "{s}Store", .{mod_pascal});
    defer allocator.free(store_name);
    const svc_name = try std.fmt.allocPrint(allocator, "{s}Service", .{mod_pascal});
    defer allocator.free(svc_name);

    try w.writeAll("// @generated by `zf crud:zent` — AI: edit inside ai-edit-zone only.\n");
    try w.writeAll("const std = @import(\"std\");\nconst persist = @import(\"persistence.zig\");\n\n");
    try w.print("pub const {s} = struct {{\n", .{svc_name});
    try w.print("    store: *persist.{s},\n\n", .{store_name});
    try w.print("    pub fn init(store: *persist.{s}) @This() {{\n", .{store_name});
    try w.writeAll("        return .{ .store = store };\n    }\n\n");

    for (schema.entities.items) |ent| {
        try w.print("    pub fn create{s}(self: *@This()", .{ent.name});
        for (ent.fields.items) |f| {
            try w.print(", {s}: {s}", .{ f.name, f.typ.zigType() });
        }
        try w.writeAll(") !i64 {\n");
        try w.writeAll("        // ── ai-edit-zone: business rules ────────────────────────────\n");
        for (ent.fields.items) |f| {
            if (f.typ.isOwnedSlice()) {
                try w.print("        if ({s}.len == 0) return error.InvalidInput;\n", .{f.name});
            } else if (f.typ == .int and (std.mem.endsWith(u8, f.name, "_id") or std.mem.eql(u8, f.name, "id"))) {
                try w.print("        if ({s} <= 0) return error.InvalidInput;\n", .{f.name});
            }
        }
        try w.writeAll("        // ── end ai-edit-zone ──────────────────────────────────────\n");
        try w.print("        return try self.store.create{s}(", .{ent.name});
        for (ent.fields.items, 0..) |f, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(f.name);
        }
        try w.writeAll(");\n    }\n\n");

        if (ent.list_by) |lb| {
            const lb_pascal = try pascalize(allocator, lb);
            defer allocator.free(lb_pascal);
            try w.print("    pub fn list{s}(self: *@This(), {s}: i64) ![]persist.{s}.{s}Row {{\n", .{
                ent.name, lb, store_name, ent.name,
            });
            try w.print("        if ({s} <= 0) return error.InvalidInput;\n", .{lb});
            try w.print("        return try self.store.list{s}By{s}({s});\n", .{ ent.name, lb_pascal, lb });
            try w.writeAll("    }\n\n");
            try w.print("    pub fn free{s}s(self: *@This(), rows: []persist.{s}.{s}Row) void {{\n", .{
                ent.name, store_name, ent.name,
            });
            try w.print("        self.store.free{s}s(rows);\n    }}\n\n", .{ent.name});
        }
    }

    try w.writeAll(
        \\    // ── ai-edit-zone: extra service methods ───────────────────────
        \\    // ── end ai-edit-zone ──────────────────────────────────────────
        \\};
        \\
    );
    return try aw.toOwnedSlice();
}

pub fn generateHandler(allocator: std.mem.Allocator, schema: *const Schema) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    const mod_pascal = try pascalize(allocator, schema.module);
    defer allocator.free(mod_pascal);
    const svc_name = try std.fmt.allocPrint(allocator, "{s}Service", .{mod_pascal});
    defer allocator.free(svc_name);

    try w.writeAll("// @generated by `zf crud:zent` — AI: edit inside ai-edit-zone only.\n");
    try w.writeAll("const std = @import(\"std\");\nconst zfinal = @import(\"zfinal\");\nconst service = @import(\"service.zig\");\n\n");
    try w.print("pub var g_svc: ?*service.{s} = null;\n\n", .{svc_name});
    try w.print("fn svcOrErr(ctx: *zfinal.Context) !*service.{s} {{\n", .{svc_name});
    try w.writeAll("    _ = ctx;\n    return g_svc orelse error.ServiceNotReady;\n}\n\n");
    try w.writeAll("pub fn register(app: *zfinal.ZFinal) !void {\n");
    try w.print("    var api = zfinal.RouteGroup.init(app, \"{s}\");\n", .{schema.api_prefix});

    var name_buf: [128]u8 = undefined;
    for (schema.entities.items) |ent| {
        const cname = ent.clientName(&name_buf);
        const plural = try pluralize(allocator, cname);
        defer allocator.free(plural);
        try w.print("    _ = try api.post(\"/{s}\", create{s});\n", .{ plural, ent.name });
        if (ent.list_by != null) {
            try w.print("    _ = try api.get(\"/{s}\", list{s});\n", .{ plural, ent.name });
        }
    }
    try w.writeAll(
        \\    // ── ai-edit-zone: extra routes ────────────────────────────────
        \\    // ── end ai-edit-zone ──────────────────────────────────────────
        \\}
        \\
    );

    for (schema.entities.items) |ent| {
        try w.print("fn create{s}(ctx: *zfinal.Context) !void {{\n", .{ent.name});
        try w.writeAll("    const svc = try svcOrErr(ctx);\n");
        try w.writeAll("    // ── ai-edit-zone: handler hooks ───────────────────────────────\n");
        for (ent.fields.items) |f| {
            if (f.typ.isOwnedSlice()) {
                try w.print("    const {s} = try ctx.getPara(\"{s}\") orelse {{\n", .{ f.name, f.name });
                try w.print("        try ctx.renderJson(.{{ .ok = false, .error_msg = \"Missing {s}\" }});\n", .{f.name});
                try w.writeAll("        return;\n    };\n");
            } else if (f.typ == .int or f.typ == .time) {
                if (f.default_value) |dv| {
                    try w.print("    const {s} = try ctx.getParaToLongDefault(\"{s}\", {s});\n", .{ f.name, f.name, dv });
                } else {
                    try w.print("    const {s} = try ctx.getParaToLong(\"{s}\") orelse {{\n", .{ f.name, f.name });
                    try w.print("        try ctx.renderJson(.{{ .ok = false, .error_msg = \"Missing {s}\" }});\n", .{f.name});
                    try w.writeAll("        return;\n    };\n");
                }
            } else if (f.typ == .bool) {
                try w.print("    const {s}_raw = try ctx.getPara(\"{s}\");\n", .{ f.name, f.name });
                try w.print("    const {s} = if ({s}_raw) |v| std.mem.eql(u8, v, \"true\") or std.mem.eql(u8, v, \"1\") else false;\n", .{ f.name, f.name });
            } else {
                try w.print("    const {s} = try ctx.getParaToLongDefault(\"{s}\", 0);\n", .{ f.name, f.name });
            }
        }
        try w.writeAll("    // ── end ai-edit-zone ──────────────────────────────────────────\n");
        try w.print("    const id = svc.create{s}(", .{ent.name});
        for (ent.fields.items, 0..) |f, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(f.name);
        }
        try w.writeAll(") catch |err| {\n");
        try w.writeAll("        try ctx.renderJson(.{ .ok = false, .error_msg = @errorName(err) });\n");
        try w.writeAll("        return;\n    };\n");
        try w.writeAll("    try ctx.renderJson(.{ .ok = true, .id = id });\n}\n\n");

        if (ent.list_by) |lb| {
            const cname = ent.clientName(&name_buf);
            const plural = try pluralize(allocator, cname);
            defer allocator.free(plural);
            try w.print("fn list{s}(ctx: *zfinal.Context) !void {{\n", .{ent.name});
            try w.writeAll("    const svc = try svcOrErr(ctx);\n");
            try w.print("    const {s} = try ctx.getParaToLong(\"{s}\") orelse {{\n", .{ lb, lb });
            try w.print("        try ctx.renderJson(.{{ .ok = false, .error_msg = \"Missing {s}\" }});\n", .{lb});
            try w.writeAll("        return;\n    };\n");
            try w.print("    const rows = svc.list{s}({s}) catch |err| {{\n", .{ ent.name, lb });
            try w.writeAll("        try ctx.renderJson(.{ .ok = false, .error_msg = @errorName(err) });\n");
            try w.writeAll("        return;\n    };\n");
            try w.print("    defer svc.free{s}s(rows);\n", .{ent.name});
            try w.print("    try ctx.renderJson(.{{ .ok = true, .{s} = rows }});\n}}\n\n", .{plural});
        }
    }
    return try aw.toOwnedSlice();
}

pub fn generateRoutes(allocator: std.mem.Allocator, schema: *const Schema) ![]u8 {
    _ = schema;
    return try allocator.dupe(u8,
        \\// @generated by `zf crud:zent` — thin route registration.
        \\const zfinal = @import("zfinal");
        \\const handler = @import("handler.zig");
        \\
        \\pub fn register(app: *zfinal.ZFinal) !void {
        \\    try handler.register(app);
        \\}
        \\
    );
}

pub fn generateBootstrapSnippet(allocator: std.mem.Allocator, schema: *const Schema) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    const mod_pascal = try pascalize(allocator, schema.module);
    defer allocator.free(mod_pascal);
    const store_name = try std.fmt.allocPrint(allocator, "{s}Store", .{mod_pascal});
    defer allocator.free(store_name);
    const svc_name = try std.fmt.allocPrint(allocator, "{s}Service", .{mod_pascal});
    defer allocator.free(svc_name);

    try w.writeAll("// ── paste into main.zig (zent primary data layer) ──\n");
    try w.writeAll("const zfinal = @import(\"zfinal\");\nconst zent = zfinal.zent;\n");
    try w.print("const persist = @import(\"modules/{s}/persistence.zig\");\n", .{schema.module});
    try w.print("const service = @import(\"modules/{s}/service.zig\");\n", .{schema.module});
    try w.print("const handler = @import(\"modules/{s}/handler.zig\");\n\n", .{schema.module});
    try w.writeAll("var drv = try zent.sql_sqlite.SQLiteDriver.open(allocator, \"app.db\");\ndefer drv.close();\n");
    try w.writeAll("try zent.sql_schema.migrateSchema(allocator, drv.asDriver(), persist.infos);\n");
    try w.print("var store = persist.{s}.init(allocator, drv.asDriver());\n", .{store_name});
    try w.print("var svc = service.{s}.init(&store);\n", .{svc_name});
    try w.writeAll("handler.g_svc = &svc;\ntry handler.register(&app);\n");
    return try aw.toOwnedSlice();
}

pub fn emitJsonManifest(allocator: std.mem.Allocator, schema_path: []const u8, schema: *const Schema) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\n  \"$schema\": \"https://zfinal.dev/schemas/zent-manifest-1.json\",\n");
    try w.writeAll("  \"version\": \"0.13.10\",\n  \"generator\": \"zf crud:zent\",\n");
    try w.print("  \"schema_path\": \"{s}\",\n", .{schema_path});
    try w.print("  \"module\": \"{s}\",\n", .{schema.module});
    try w.print("  \"api_prefix\": \"{s}\",\n", .{schema.api_prefix});
    try w.writeAll("  \"data_layer\": \"zent\",\n");
    try w.writeAll("  \"ai_primary\": true,\n");
    try w.writeAll("  \"files\": {\n");
    try w.print("    \"model\": \"src/modules/{s}/model.zig\",\n", .{schema.module});
    try w.print("    \"persistence\": \"src/modules/{s}/persistence.zig\",\n", .{schema.module});
    try w.print("    \"service\": \"src/modules/{s}/service.zig\",\n", .{schema.module});
    try w.print("    \"handler\": \"src/modules/{s}/handler.zig\",\n", .{schema.module});
    try w.print("    \"routes\": \"src/modules/{s}/routes.zig\"\n", .{schema.module});
    try w.writeAll("  },\n  \"ai_edit_zones\": [\n");
    try w.writeAll("    { \"file\": \"model.zig\", \"markers\": [\"// ── ai-edit-zone: model hooks\"], \"purpose\": \"edges, privacy, extra Schema\" },\n");
    try w.writeAll("    { \"file\": \"persistence.zig\", \"markers\": [\"// ── ai-edit-zone: custom queries\"], \"purpose\": \"domain queries, joins, aggregates\" },\n");
    try w.writeAll("    { \"file\": \"service.zig\", \"markers\": [\"// ── ai-edit-zone: business rules\", \"// ── ai-edit-zone: extra service methods\"], \"purpose\": \"validation, orchestration\" },\n");
    try w.writeAll("    { \"file\": \"handler.zig\", \"markers\": [\"// ── ai-edit-zone: handler hooks\", \"// ── ai-edit-zone: extra routes\"], \"purpose\": \"auth, response shaping, custom routes\" }\n");
    try w.writeAll("  ],\n  \"entities\": [\n");
    for (schema.entities.items, 0..) |ent, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.writeAll("    {\n");
        try w.print("      \"name\": \"{s}\"", .{ent.name});
        if (ent.list_by) |lb| try w.print(",\n      \"list_by\": \"{s}\"", .{lb});
        try w.writeAll(",\n      \"fields\": [\n");
        for (ent.fields.items, 0..) |f, fi| {
            if (fi > 0) try w.writeAll(",\n");
            try w.print("        {{\"name\": \"{s}\", \"type\": \"{s}\"", .{ f.name, @tagName(f.typ) });
            if (f.indexed) try w.writeAll(", \"index\": true");
            try w.writeAll("}");
        }
        try w.writeAll("\n      ]\n    }");
    }
    try w.writeAll("\n  ],\n  \"next_steps\": [\n");
    try w.writeAll("    \"ALWAYS use --json and parse files + ai_edit_zones before editing\",\n");
    try w.writeAll("    \"Wire migrateSchema + Store + Service in main.zig (bootstrap snippet on stderr)\",\n");
    try w.writeAll("    \"Edit ONLY inside // ── ai-edit-zone blocks — never rewrite generated Create/Query\",\n");
    try w.writeAll("    \"Do NOT mix zfinal.DB and zent.Driver in one transaction\",\n");
    try w.writeAll("    \"zf check && zig build test\"\n  ]\n}\n");
    return try aw.toOwnedSlice();
}
