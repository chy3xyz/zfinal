//! zf crud:zent — generate ZFinal modules for the zent data layer.
//!
//! Input: `.zent` DSL or `.json` schema.
//! Output: `src/modules/<module>/{model,persistence,service,handler,routes}.zig`
//! Parallel to `codegen.zig` (SQL → DB/Model). Do not mix stacks in one Tx.

const std = @import("std");
/// Shared identifier helpers (`isValidBareZigIdent`, `zigFieldName`).
const codegen = @import("codegen");

pub const FieldType = enum {
    string,
    text,
    int,
    bool,
    float,
    time,
    uuid,
    bytes,
    enum_,

    pub fn fromToken(tok: []const u8) ?FieldType {
        if (std.mem.eql(u8, tok, "string") or std.mem.eql(u8, tok, "str")) return .string;
        if (std.mem.eql(u8, tok, "text")) return .text;
        if (std.mem.eql(u8, tok, "int") or std.mem.eql(u8, tok, "i64") or std.mem.eql(u8, tok, "integer")) return .int;
        if (std.mem.eql(u8, tok, "bool") or std.mem.eql(u8, tok, "boolean")) return .bool;
        if (std.mem.eql(u8, tok, "float") or std.mem.eql(u8, tok, "f64") or std.mem.eql(u8, tok, "double")) return .float;
        if (std.mem.eql(u8, tok, "time") or std.mem.eql(u8, tok, "datetime") or std.mem.eql(u8, tok, "timestamp")) return .time;
        if (std.mem.eql(u8, tok, "uuid")) return .uuid;
        if (std.mem.eql(u8, tok, "bytes") or std.mem.eql(u8, tok, "blob")) return .bytes;
        if (std.mem.startsWith(u8, tok, "enum")) return .enum_;
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
            .uuid => "UUID",
            .bytes => "Bytes",
            .enum_ => "Enum",
        };
    }

    pub fn zigType(self: FieldType) []const u8 {
        return switch (self) {
            .string, .text, .uuid, .bytes, .enum_ => "[]const u8",
            .int, .time => "i64",
            .bool => "bool",
            .float => "f64",
        };
    }

    pub fn isOwnedSlice(self: FieldType) bool {
        return self == .string or self == .text or self == .uuid or self == .bytes or self == .enum_;
    }

    /// zent sql.Value tag used by predicate EQ calls (null = unsupported).
    pub fn valueTag(self: FieldType) ?[]const u8 {
        return switch (self) {
            .string, .text, .uuid, .enum_ => "string",
            .int => "int",
            .bool => "bool",
            .float => "float",
            .bytes => "bytes",
            .time => null,
        };
    }
};

pub const Field = struct {
    name: []const u8,
    typ: FieldType,
    indexed: bool = false,
    default_value: ?[]const u8 = null,
    unique: bool = false,
    sensitive: bool = false,
    required: bool = false,
    email: bool = false,
    positive: bool = false,
    /// Enum literal values (owned by this Field; freed in deinit).
    enum_values: []const []const u8 = &.{},

    /// string/text fields accept NotEmpty()/Email() chain calls.
    pub fn isStringLike(self: Field) bool {
        return self.typ == .string or self.typ == .text;
    }

    /// int/float fields accept Positive()/Range() chain calls.
    pub fn isNumeric(self: Field) bool {
        return self.typ == .int or self.typ == .float;
    }

    pub fn deinit(self: *Field, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.default_value) |d| allocator.free(d);
        for (self.enum_values) |v| allocator.free(v);
        if (self.enum_values.len > 0) allocator.free(self.enum_values);
    }
};

pub const Ref = struct {
    name: []const u8, // edge name (author)
    target: []const u8, // target entity (User)
    field: []const u8, // FK field on this entity (author_id)

    pub fn deinit(self: *Ref, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.target);
        allocator.free(self.field);
    }
};

pub const Entity = struct {
    name: []const u8,
    fields: std.ArrayList(Field),
    list_by: ?[]const u8 = null,
    refs: std.ArrayList(Ref) = .empty,
    policy: bool = false, // `policy: data_scope` → .policy = zent.data_scope.Policy
    /// Composite-unique field names (`unique: a, b`); each owned.
    unique_fields: []const []const u8 = &.{},

    pub fn deinit(self: *Entity, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.fields.items) |*f| f.deinit(allocator);
        self.fields.deinit(allocator);
        if (self.list_by) |lb| allocator.free(lb);
        for (self.refs.items) |*r| r.deinit(allocator);
        self.refs.deinit(allocator);
        for (self.unique_fields) |uf| allocator.free(uf);
        if (self.unique_fields.len > 0) allocator.free(self.unique_fields);
    }

    pub fn clientName(self: Entity, buf: []u8) []const u8 {
        // zent Client field names are snake_case: CartItem → cart_item.
        var i: usize = 0;
        for (self.name) |c| {
            if (std.ascii.isUpper(c) and i > 0) {
                if (i >= buf.len) return "";
                buf[i] = '_';
                i += 1;
            }
            if (i >= buf.len) return "";
            buf[i] = std.ascii.toLower(c);
            i += 1;
        }
        return buf[0..i];
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

/// Render a schema field name for a Zig *identifier* position (struct field,
/// function parameter, local variable, field-init/field-access, predicate
/// method). Reserved words and non-ASCII names become quoted identifiers
/// (`@"const"`, `@"中文"`) while `std.meta.fields(T).name` keeps the real
/// schema name. Schema/string positions (`field.String("const")`,
/// `setFieldValue("const", …)`, `getPara("const")`) must keep the raw name.
/// Caller frees.
fn zigIdent(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return codegen.zigFieldName(allocator, name);
}

/// Like `zigIdent`, but for identifiers assembled from parts, e.g.
/// `findByUnique` + PascalCase(field), `<field>EQ`, `<field>_raw`. The joined
/// text is sanitized as a whole so `@"中文EQ"` stays one quoted identifier.
/// Caller frees.
fn zigIdentCat(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8, suffix: []const u8) ![]const u8 {
    const joined = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, name, suffix });
    defer allocator.free(joined);
    return codegen.zigFieldName(allocator, joined);
}

/// Name of the paginated list function: `list<Entity>By<Pascal(field)>`.
/// Sanitized as a whole so reserved-word / non-ASCII field names stay valid
/// (`listItemBy中文` → `@"listItemBy中文"`). Caller frees.
fn listByFn(allocator: std.mem.Allocator, ent_name: []const u8, field_pascal: []const u8) ![]const u8 {
    const joined = try std.fmt.allocPrint(allocator, "list{s}By{s}", .{ ent_name, field_pascal });
    defer allocator.free(joined);
    return codegen.zigFieldName(allocator, joined);
}

/// Escape `s` for the *body* of a Zig string literal (no surrounding quotes):
/// backslash, double quote and control bytes. Schema names reach string
/// positions (`Schema("…")`, `setFieldValue("…")`, `getPara("…")`) unescaped
/// otherwise. Caller frees.
fn zigStr(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (s) |c| switch (c) {
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        else => if (c < 0x20) {
            var esc: [8]u8 = undefined;
            try buf.appendSlice(allocator, try std.fmt.bufPrint(&esc, "\\x{x:0>2}", .{c}));
        } else {
            try buf.append(allocator, c);
        },
    };
    return buf.toOwnedSlice(allocator);
}

/// Escape `s` for the *body* of a JSON string (no surrounding quotes).
/// Mirrors `zf_shared.appendJsonString`; kept local so zent_codegen does not
/// need a new build.zig module dependency. Caller frees.
fn jsonStr(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        0x08 => try buf.appendSlice(allocator, "\\b"),
        0x0C => try buf.appendSlice(allocator, "\\f"),
        else => if (c < 0x20) {
            var esc: [8]u8 = undefined;
            try buf.appendSlice(allocator, try std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c}));
        } else {
            try buf.append(allocator, c);
        },
    };
    return buf.toOwnedSlice(allocator);
}

/// Every entity-derived Zig symbol name, pre-sanitized for identifier
/// positions. Address these through an arena so nothing leaks.
const EntNames = struct {
    ident: []const u8, // `pub const <Ent>` / `model.<Ent>`
    info: []const u8, // `<Ent>Info`
    row: []const u8, // `<Ent>Row`
    page: []const u8, // `<Ent>Page`
    create_fn: []const u8, // `create<Ent>`
    update_fn: []const u8, // `update<Ent>`
    delete_fn: []const u8, // `delete<Ent>`
    find_unique_fn: []const u8, // `findUnique<Ent>`
    list_fn: []const u8, // `list<Ent>`
    free_fn: []const u8, // `free<Ent>s`
    client: []const u8, // zent Client accessor (`self.client.<client>`)
};

fn entityNames(allocator: std.mem.Allocator, ent: Entity, client_name: []const u8) !EntNames {
    return .{
        .ident = try zigIdent(allocator, ent.name),
        .info = try zigIdentCat(allocator, "", ent.name, "Info"),
        .row = try zigIdentCat(allocator, "", ent.name, "Row"),
        .page = try zigIdentCat(allocator, "", ent.name, "Page"),
        .create_fn = try zigIdentCat(allocator, "create", ent.name, ""),
        .update_fn = try zigIdentCat(allocator, "update", ent.name, ""),
        .delete_fn = try zigIdentCat(allocator, "delete", ent.name, ""),
        .find_unique_fn = try zigIdentCat(allocator, "findUnique", ent.name, ""),
        .list_fn = try zigIdentCat(allocator, "list", ent.name, ""),
        .free_fn = try zigIdentCat(allocator, "free", ent.name, "s"),
        .client = try zigIdent(allocator, client_name),
    };
}

/// `<Module>Store` / `<Module>Service`, sanitized for identifier positions.
const ModuleNames = struct {
    store: []const u8,
    service: []const u8,
};

fn moduleNames(allocator: std.mem.Allocator, module: []const u8) !ModuleNames {
    const pascal = try pascalize(allocator, module);
    return .{
        .store = try zigIdent(allocator, try std.fmt.allocPrint(allocator, "{s}Store", .{pascal})),
        .service = try zigIdent(allocator, try std.fmt.allocPrint(allocator, "{s}Service", .{pascal})),
    };
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

        // policy: data_scope  → zent privacy/data_scope row-level security
        if (std.mem.eql(u8, line, "policy: data_scope")) {
            current.?.policy = true;
            continue;
        }

        // unique: a, b  → composite-unique fields (generates findUnique* + dedup)
        if (std.mem.startsWith(u8, line, "unique:")) {
            var uf_list: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (uf_list.items) |v| allocator.free(v);
                uf_list.deinit(allocator);
            }
            var it = std.mem.splitScalar(u8, line["unique:".len..], ',');
            while (it.next()) |v| {
                const t = std.mem.trim(u8, v, " \t");
                if (t.len == 0) continue;
                try uf_list.append(allocator, try allocator.dupe(u8, t));
            }
            if (uf_list.items.len < 2) return error.InvalidUniqueFields;
            current.?.unique_fields = try uf_list.toOwnedSlice(allocator);
            continue;
        }

        // ref: <edge_name>: <TargetEntity> via <fk_field>  → zent From edge
        if (std.mem.startsWith(u8, line, "ref:")) {
            const v = std.mem.trim(u8, line["ref:".len..], " \t");
            const colon = std.mem.indexOfScalar(u8, v, ':') orelse return error.InvalidRefLine;
            const name = std.mem.trim(u8, v[0..colon], " \t");
            const rest = std.mem.trim(u8, v[colon + 1 ..], " \t");
            const via_kw = std.mem.indexOf(u8, rest, "via") orelse return error.InvalidRefLine;
            const target = std.mem.trim(u8, rest[0..via_kw], " \t");
            const field_name = std.mem.trim(u8, rest[via_kw + 3 ..], " \t");
            if (name.len == 0 or target.len == 0 or field_name.len == 0) return error.InvalidRefLine;
            try current.?.refs.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .target = try allocator.dupe(u8, target),
                .field = try allocator.dupe(u8, field_name),
            });
            // Ensure the FK column exists in our field list so generated
            // create/Row/list code can reference it. zent's addEdgeFields
            // auto-adds the column from the edge, so generateModel skips it.
            var fk_exists = false;
            for (current.?.fields.items) |*f| {
                if (std.mem.eql(u8, f.name, field_name)) {
                    fk_exists = true;
                    break;
                }
            }
            if (!fk_exists) {
                try current.?.fields.append(allocator, .{
                    .name = try allocator.dupe(u8, field_name),
                    .typ = .int,
                });
            }
            continue;
        }

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidFieldLine;
        const fname = std.mem.trim(u8, line[0..colon], " \t");
        const rhs = std.mem.trim(u8, line[colon + 1 ..], " \t");

        var indexed = false;
        var unique = false;
        var sensitive = false;
        var required = false;
        var email = false;
        var positive = false;
        var default_value: ?[]const u8 = null;
        var type_tok: []const u8 = rhs;

        // tokens: type [@index] [@unique] [@sensitive] [@required] [@email] [@positive] [= default]
        var tok_it = std.mem.tokenizeAny(u8, rhs, " \t");
        const first = tok_it.next() orelse return error.InvalidFieldLine;
        type_tok = first;
        while (tok_it.next()) |tok| {
            if (std.mem.eql(u8, tok, "@index")) {
                indexed = true;
            } else if (std.mem.eql(u8, tok, "@unique")) {
                unique = true;
            } else if (std.mem.eql(u8, tok, "@sensitive")) {
                sensitive = true;
            } else if (std.mem.eql(u8, tok, "@required")) {
                required = true;
            } else if (std.mem.eql(u8, tok, "@email")) {
                email = true;
            } else if (std.mem.eql(u8, tok, "@positive")) {
                positive = true;
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

        // enum(a,b,c) → field.Enum values (owned by the Field).
        var enum_vals: []const []const u8 = &.{};
        if (typ == .enum_) {
            if (std.mem.indexOfScalar(u8, type_tok, '(')) |open| {
                if (std.mem.lastIndexOfScalar(u8, type_tok, ')')) |close| {
                    var list: std.ArrayList([]const u8) = .empty;
                    errdefer {
                        for (list.items) |v| allocator.free(v);
                        list.deinit(allocator);
                    }
                    var it = std.mem.splitScalar(u8, type_tok[open + 1 .. close], ',');
                    while (it.next()) |v| {
                        const t = std.mem.trim(u8, v, " \t\"'");
                        if (t.len == 0) continue;
                        try list.append(allocator, try allocator.dupe(u8, t));
                    }
                    enum_vals = try list.toOwnedSlice(allocator);
                }
            }
            if (enum_vals.len == 0) return error.InvalidEnumValues;
        }

        try current.?.fields.append(allocator, .{
            .name = try allocator.dupe(u8, fname),
            .typ = typ,
            .indexed = indexed,
            .default_value = default_value,
            .unique = unique,
            .sensitive = sensitive,
            .required = required,
            .email = email,
            .positive = positive,
            .enum_values = enum_vals,
        });
    }

    if (schema.entities.items.len == 0) return error.NoEntities;
    return schema;
}

const JsonField = struct {
    name: []const u8,
    type: []const u8,
    index: ?bool = null,
    default: ?[]const u8 = null,
    unique: ?bool = null,
    sensitive: ?bool = null,
    required: ?bool = null,
    email: ?bool = null,
    positive: ?bool = null,
    enum_values: ?[]const []const u8 = null,
};

const JsonRef = struct {
    name: []const u8,
    target: []const u8,
    field: []const u8,
};

const JsonEntity = struct {
    name: []const u8,
    fields: []JsonField,
    list_by: ?[]const u8 = null,
    refs: ?[]JsonRef = null,
    policy: ?bool = null,
    unique_fields: ?[]const []const u8 = null,
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
            .policy = je.policy orelse false,
        };
        if (je.unique_fields) |ufs| {
            var uf_list: std.ArrayList([]const u8) = .empty;
            for (ufs) |uf| {
                try uf_list.append(allocator, try allocator.dupe(u8, uf));
            }
            ent.unique_fields = try uf_list.toOwnedSlice(allocator);
        }
        if (je.refs) |refs| {
            for (refs) |jr| {
                try ent.refs.append(allocator, .{
                    .name = try allocator.dupe(u8, jr.name),
                    .target = try allocator.dupe(u8, jr.target),
                    .field = try allocator.dupe(u8, jr.field),
                });
                // FK column must exist in fields (see ref parsing in DSL path).
                var fk_exists = false;
                for (ent.fields.items) |*f| {
                    if (std.mem.eql(u8, f.name, jr.field)) {
                        fk_exists = true;
                        break;
                    }
                }
                if (!fk_exists) {
                    try ent.fields.append(allocator, .{
                        .name = try allocator.dupe(u8, jr.field),
                        .typ = .int,
                    });
                }
            }
        }
        for (je.fields) |jf| {
            const typ = FieldType.fromToken(jf.type) orelse return error.UnknownFieldType;
            var enum_vals: []const []const u8 = &.{};
            if (typ == .enum_) {
                if (jf.enum_values) |vals| {
                    var list: std.ArrayList([]const u8) = .empty;
                    for (vals) |v| {
                        try list.append(allocator, try allocator.dupe(u8, v));
                    }
                    enum_vals = try list.toOwnedSlice(allocator);
                }
                if (enum_vals.len == 0) return error.InvalidEnumValues;
            }
            try ent.fields.append(allocator, .{
                .name = try allocator.dupe(u8, jf.name),
                .typ = typ,
                .indexed = jf.index orelse false,
                .default_value = if (jf.default) |d| try allocator.dupe(u8, d) else null,
                .unique = jf.unique orelse false,
                .sensitive = jf.sensitive orelse false,
                .required = jf.required orelse false,
                .email = jf.email orelse false,
                .positive = jf.positive orelse false,
                .enum_values = enum_vals,
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
    var name_arena = std.heap.ArenaAllocator.init(allocator);
    defer name_arena.deinit();
    const na = name_arena.allocator();

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
        try w.print("\npub const {s} = Schema(\"{s}\", .{{\n", .{ try zigIdent(na, ent.name), try zigStr(na, ent.name) });
        try w.writeAll("    .fields = &.{\n");
        for (ent.fields.items) |f| {
            if (f.typ == .enum_) {
                try w.print("        field.Enum(\"{s}\", &.{{", .{try zigStr(na, f.name)});
                for (f.enum_values, 0..) |v, vi| {
                    if (vi > 0) try w.writeAll(", ");
                    try w.print("\"{s}\"", .{try zigStr(na, v)});
                }
                try w.writeAll("})");
            } else {
                try w.print("        field.{s}(\"{s}\")", .{ f.typ.zentCtor(), try zigStr(na, f.name) });
            }
            if (f.default_value) |dv| try w.print(".Default(\"{s}\")", .{try zigStr(na, dv)});
            if (f.unique) try w.writeAll(".Unique()");
            if (f.sensitive) try w.writeAll(".Sensitive()");
            if (f.required and f.isStringLike()) try w.writeAll(".NotEmpty()");
            if (f.email and f.isStringLike()) try w.writeAll(".Email()");
            if (f.positive and f.isNumeric()) try w.writeAll(".Positive()");
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
        if (any_index or ent.unique_fields.len > 0) {
            try w.writeAll("    .indexes = &.{\n");
            for (ent.fields.items) |f| {
                if (!f.indexed) continue;
                try w.print("        zent.core.index.Fields(&.{{\"{s}\"}}),\n", .{try zigStr(na, f.name)});
            }
            // composite unique (`unique: a, b`) → DB-level UNIQUE index
            // (guards against concurrent create races beyond the findUnique
            // pre-check).
            if (ent.unique_fields.len > 0) {
                try w.writeAll("        zent.core.index.Fields(&.{");
                for (ent.unique_fields, 0..) |uf, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.print("\"{s}\"", .{try zigStr(na, uf)});
                }
                try w.writeAll("}).Unique(),\n");
            }
            try w.writeAll("    },\n");
        }
        if (ent.refs.items.len > 0) {
            try w.writeAll("    .edges = &.{\n");
            for (ent.refs.items) |r| {
                try w.print("        zent.core.edge.From(\"{s}\", {s}).Field(\"{s}\"),\n", .{ try zigStr(na, r.name), try zigIdent(na, r.target), try zigStr(na, r.field) });
            }
            try w.writeAll("    },\n");
        }
        if (ent.policy) {
            try w.writeAll("    .policy = zent.data_scope.Policy,\n");
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

    var name_arena = std.heap.ArenaAllocator.init(allocator);
    defer name_arena.deinit();
    const na = name_arena.allocator();
    const store_name = (try moduleNames(na, schema.module)).store;

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
        try w.print("model.{s}", .{try zigIdent(na, ent.name)});
    }
    try w.writeAll(
        \\ });
        \\pub const infos = graph.types;
        \\pub const Client = zent.codegen.client.Client(infos);
        \\
    );
    for (schema.entities.items, 0..) |ent, i| {
        try w.print("const {s} = infos[{d}];\n", .{ try zigIdentCat(na, "", ent.name, "Info"), i });
    }

    try w.print("\npub const {s} = struct {{\n", .{store_name});
    try w.writeAll(
        \\    allocator: std.mem.Allocator,
        \\    client: Client,
        \\
        \\    pub fn init(allocator: std.mem.Allocator, driver: zent.sql_driver.Driver) @This() {
        \\        const client = zent.codegen.client.makeClient(infos, allocator, driver);
        \\        // ── ai-edit-zone: hook wiring ─────────────────────────────
        \\        // Lifecycle hooks (zent.runtime.hook): define callbacks in the
        \\        // custom queries zone, then attach. Needs `var client`:
        \\        //   var client = zent.codegen.client.makeClient(infos, allocator, driver);
        \\        //   client.order = client.order.withHooks(&.{.{ .op = .create, .before = orderBeforeCreate }});
        \\        // ── end ai-edit-zone ──────────────────────────────────────
        \\        return .{
        \\            .allocator = allocator,
        \\            .client = client,
        \\        };
        \\    }
        \\
    );

    var name_buf: [128]u8 = undefined;
    for (schema.entities.items) |ent| {
        const cname = ent.clientName(&name_buf);
        const en = try entityNames(na, ent, cname);

        try w.print("    pub fn {s}(self: *@This()", .{en.create_fn});
        for (ent.fields.items) |f| {
            const fid = try zigIdent(allocator, f.name);
            defer allocator.free(fid);
            try w.print(", {s}: {s}", .{ fid, f.typ.zigType() });
        }
        try w.writeAll(") !i64 {\n");
        if (ent.policy) {
            // data_scope entities need a PrivacyContext; empty ctx → no extra
            // filter → allow-all (production should pass a real scope).
            try w.print("        var b = try self.client.{s}.withContext(.{{}}).Create();\n", .{en.client});
        } else {
            try w.print("        var b = try self.client.{s}.Create();\n", .{en.client});
        }
        try w.writeAll("        defer b.deinit();\n");
        for (ent.fields.items) |f| {
            const fid = try zigIdent(allocator, f.name);
            defer allocator.free(fid);
            try w.print("        _ = try b.setFieldValue(\"{s}\", {s});\n", .{ try zigStr(na, f.name), fid });
        }
        try w.writeAll("        var row = try b.Save();\n");
        try w.print("        defer zent.codegen.deinitEntity(infos, {s}, &row, self.allocator);\n", .{en.info});
        try w.writeAll("        return row.id;\n    }\n\n");

        // update + delete (full CRUD)
        try w.print("    /// Update a {s} row by id (sets every declared field).\n", .{ent.name});
        try w.print("    pub fn {s}(self: *@This(), id: i64", .{en.update_fn});
        for (ent.fields.items) |f| {
            const fid = try zigIdent(allocator, f.name);
            defer allocator.free(fid);
            try w.print(", {s}: {s}", .{ fid, f.typ.zigType() });
        }
        try w.writeAll(") !void {\n");
        if (ent.policy) {
            try w.print("        var ub = self.client.{s}.withContext(.{{}}).Update();\n", .{en.client});
        } else {
            try w.print("        var ub = self.client.{s}.Update();\n", .{en.client});
        }
        try w.writeAll("        defer ub.deinit();\n");
        for (ent.fields.items) |f| {
            const fid = try zigIdent(allocator, f.name);
            defer allocator.free(fid);
            try w.print("        _ = try ub.setFieldValue(\"{s}\", {s});\n", .{ try zigStr(na, f.name), fid });
        }
        try w.print("        _ = try ub.Where(.{{self.client.{s}.predicates.idEQ(.{{ .int = id }})}});\n", .{en.client});
        try w.writeAll("        _ = try ub.Save();\n    }\n\n");

        try w.print("    /// Delete a {s} row by id.\n", .{ent.name});
        try w.print("    pub fn {s}(self: *@This(), id: i64) !void {{\n", .{en.delete_fn});
        if (ent.policy) {
            try w.print("        var db = self.client.{s}.withContext(.{{}}).Delete();\n", .{en.client});
        } else {
            try w.print("        var db = self.client.{s}.Delete();\n", .{en.client});
        }
        try w.writeAll("        defer db.deinit();\n");
        try w.print("        _ = try db.Where(.{{self.client.{s}.predicates.idEQ(.{{ .int = id }})}});\n", .{en.client});
        try w.writeAll("        _ = try db.Exec();\n    }\n\n");

        // unique lookups (@unique fields) — used by service create/update dedup.
        for (ent.fields.items) |f| {
            if (!f.unique) continue;
            const vtag = f.typ.valueTag() orelse continue; // time unsupported
            const fp = try pascalize(allocator, f.name);
            defer allocator.free(fp);
            const fid = try zigIdent(allocator, f.name);
            defer allocator.free(fid);
            const fn_name = try zigIdentCat(allocator, "findByUnique", fp, "");
            defer allocator.free(fn_name);
            const pred_name = try zigIdentCat(allocator, "", f.name, "EQ");
            defer allocator.free(pred_name);
            try w.print("    /// Returns the id of the row whose `{s}` equals `value`, or null.\n", .{f.name});
            try w.print("    pub fn {s}(self: *@This(), {s}: {s}) !?i64 {{\n", .{ fn_name, fid, f.typ.zigType() });
            if (ent.policy) {
                try w.print("        var q = self.client.{s}.withContext(.{{}}).Query();\n", .{en.client});
            } else {
                try w.print("        var q = self.client.{s}.Query();\n", .{en.client});
            }
            try w.writeAll("        defer q.deinit();\n");
            try w.print("        const preds = self.client.{s}.predicates;\n", .{en.client});
            try w.print("        _ = try q.Where(.{{preds.{s}(.{{ .{s} = {s} }})}});\n", .{ pred_name, vtag, fid });
            try w.writeAll("        var found = try q.All();\n");
            try w.writeAll("        defer {\n            for (found.items) |*p| {\n");
            try w.print("                zent.codegen.deinitEntity(infos, {s}, p, self.allocator);\n", .{en.info});
            try w.writeAll("            }\n            found.deinit();\n        }\n");
            try w.writeAll("        if (found.items.len == 0) return null;\n        return found.items[0].id;\n    }\n\n");
        }

        // composite unique (`unique: a, b`) — int fields, generates findUnique<Ent>
        if (ent.unique_fields.len > 0) {
            try w.print("    /// Composite-unique check: does a row with these values already exist?\n", .{});
            try w.print("    pub fn {s}(self: *@This()", .{en.find_unique_fn});
            for (ent.unique_fields) |uf| {
                const ufid = try zigIdent(allocator, uf);
                defer allocator.free(ufid);
                try w.print(", {s}: i64", .{ufid});
            }
            try w.writeAll(") !?i64 {\n");
            if (ent.policy) {
                try w.print("        var q = self.client.{s}.withContext(.{{}}).Query();\n", .{en.client});
            } else {
                try w.print("        var q = self.client.{s}.Query();\n", .{en.client});
            }
            try w.writeAll("        defer q.deinit();\n");
            try w.print("        const preds = self.client.{s}.predicates;\n", .{en.client});
            try w.writeAll("        _ = try q.Where(.{");
            for (ent.unique_fields, 0..) |uf, i| {
                if (i > 0) try w.writeAll(", ");
                const ufid = try zigIdent(allocator, uf);
                defer allocator.free(ufid);
                const pred_name = try zigIdentCat(allocator, "", uf, "EQ");
                defer allocator.free(pred_name);
                try w.print("preds.{s}(.{{ .int = {s} }})", .{ pred_name, ufid });
            }
            try w.writeAll("});\n");
            try w.writeAll("        var found = try q.All();\n");
            try w.writeAll("        defer {\n            for (found.items) |*e| {\n");
            try w.print("                zent.codegen.deinitEntity(infos, {s}, e, self.allocator);\n", .{en.info});
            try w.writeAll("            }\n            found.deinit();\n        }\n");
            try w.writeAll("        if (found.items.len == 0) return null;\n        return found.items[0].id;\n    }\n\n");
        }

        if (ent.list_by) |lb| {
            const lb_pascal = try pascalize(allocator, lb);
            defer allocator.free(lb_pascal);
            const lb_ident = try zigIdent(allocator, lb);
            defer allocator.free(lb_ident);
            const list_fn = try listByFn(allocator, ent.name, lb_pascal);
            defer allocator.free(list_fn);

            try w.print("    pub const {s} = struct {{\n", .{en.row});
            try w.writeAll("        id: i64,\n");
            for (ent.fields.items) |f| {
                const fid = try zigIdent(allocator, f.name);
                defer allocator.free(fid);
                try w.print("        {s}: {s},\n", .{ fid, f.typ.zigType() });
            }
            try w.writeAll("    };\n\n");

            try w.print("    pub const {s} = struct {{ rows: []{s}, total: i64 }};\n\n", .{ en.page, en.row });
            try w.print("    pub fn {s}(self: *@This(), {s}: i64, page: usize, size: usize) !{s} {{\n", .{
                list_fn, lb_ident, en.page,
            });
            if (ent.policy) {
                try w.print("        var q = self.client.{s}.withContext(.{{}}).Query();\n", .{en.client});
            } else {
                try w.print("        var q = self.client.{s}.Query();\n", .{en.client});
            }
            try w.writeAll("        defer q.deinit();\n");
            try w.print("        const preds = self.client.{s}.predicates;\n", .{en.client});
            const lb_pred = try zigIdentCat(allocator, "", lb, "EQ");
            defer allocator.free(lb_pred);
            try w.print("        _ = try q.Where(.{{preds.{s}(.{{ .int = {s} }})}});\n", .{ lb_pred, lb_ident });
            // newest first; total via Count (size=0 → all rows, legacy behavior).
            try w.writeAll("        _ = try q.OrderBy(&.{.{ .column = .{ .name = \"id\", .desc = true } }});\n");
            try w.writeAll("        if (size > 0) {\n");
            try w.writeAll("            var p = try q.paged(page, size);\n");
            try w.writeAll("            defer p.deinit();\n");
            try w.print("            var out = try self.allocator.alloc({s}, p.items.items.len);\n", .{en.row});
            try w.writeAll("            errdefer self.allocator.free(out);\n");
            try w.writeAll("            for (p.items.items, 0..) |e, i| {\n                out[i] = .{\n                    .id = e.id,\n");
            for (ent.fields.items) |f| {
                const fid = try zigIdent(allocator, f.name);
                defer allocator.free(fid);
                if (f.typ.isOwnedSlice()) {
                    try w.print("                    .{s} = try self.allocator.dupe(u8, e.{s}),\n", .{ fid, fid });
                } else {
                    try w.print("                    .{s} = e.{s},\n", .{ fid, fid });
                }
            }
            try w.writeAll("                };\n            }\n");
            try w.writeAll("            return .{ .rows = out, .total = p.total };\n        }\n");
            try w.writeAll("        const total = try q.Count();\n");
            try w.writeAll("        var found = try q.All();\n");
            try w.writeAll("        defer {\n            for (found.items) |*p| {\n");
            try w.print("                zent.codegen.deinitEntity(infos, {s}, p, self.allocator);\n", .{en.info});
            try w.writeAll("            }\n            found.deinit();\n        }\n");
            try w.print("        var out = try self.allocator.alloc({s}, found.items.len);\n", .{en.row});
            try w.writeAll("        errdefer self.allocator.free(out);\n");
            try w.writeAll("        for (found.items, 0..) |p, i| {\n            out[i] = .{\n                .id = p.id,\n");
            for (ent.fields.items) |f| {
                const fid = try zigIdent(allocator, f.name);
                defer allocator.free(fid);
                if (f.typ.isOwnedSlice()) {
                    try w.print("                .{s} = try self.allocator.dupe(u8, p.{s}),\n", .{ fid, fid });
                } else {
                    try w.print("                .{s} = p.{s},\n", .{ fid, fid });
                }
            }
            try w.writeAll("            };\n        }\n");
            try w.writeAll("        return .{ .rows = out, .total = total };\n    }\n\n");

            try w.print("    pub fn {s}(self: *@This(), rows: []{s}) void {{\n", .{ en.free_fn, en.row });
            var has_owned = false;
            for (ent.fields.items) |f| {
                if (f.typ.isOwnedSlice()) has_owned = true;
            }
            if (has_owned) {
                try w.writeAll("        for (rows) |r| {\n");
                for (ent.fields.items) |f| {
                    if (f.typ.isOwnedSlice()) {
                        const fid = try zigIdent(allocator, f.name);
                        defer allocator.free(fid);
                        try w.print("            self.allocator.free(r.{s});\n", .{fid});
                    }
                }
                try w.writeAll("        }\n");
            }
            try w.writeAll("        self.allocator.free(rows);\n    }\n\n");
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
            try w.print("        _ = {s};\n", .{try zigIdentCat(na, "", ent.name, "Info")});
        }
    }
    try w.writeAll("    }\n};\n");
    return try aw.toOwnedSlice();
}

pub fn generateService(allocator: std.mem.Allocator, schema: *const Schema) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    var name_arena = std.heap.ArenaAllocator.init(allocator);
    defer name_arena.deinit();
    const na = name_arena.allocator();
    const mn = try moduleNames(na, schema.module);
    const store_name = mn.store;
    const svc_name = mn.service;

    try w.writeAll("// @generated by `zf crud:zent` — AI: edit inside ai-edit-zone only.\n");
    try w.writeAll("const std = @import(\"std\");\nconst persist = @import(\"persistence.zig\");\n\n");
    try w.print("pub const {s} = struct {{\n", .{svc_name});
    try w.print("    store: *persist.{s},\n\n", .{store_name});
    try w.print("    pub fn init(store: *persist.{s}) @This() {{\n", .{store_name});
    try w.writeAll("        return .{ .store = store };\n    }\n\n");

    var name_buf: [128]u8 = undefined;
    for (schema.entities.items) |ent| {
        const en = try entityNames(na, ent, ent.clientName(&name_buf));

        try w.print("    pub fn {s}(self: *@This()", .{en.create_fn});
        for (ent.fields.items) |f| {
            const fid = try zigIdent(allocator, f.name);
            defer allocator.free(fid);
            try w.print(", {s}: {s}", .{ fid, f.typ.zigType() });
        }
        try w.writeAll(") !i64 {\n");
        try w.writeAll("        // ── ai-edit-zone: business rules ────────────────────────────\n");
        for (ent.fields.items) |f| {
            const fid = try zigIdent(allocator, f.name);
            defer allocator.free(fid);
            if (f.typ.isOwnedSlice()) {
                try w.print("        if ({s}.len == 0) return error.InvalidInput;\n", .{fid});
            } else if (f.typ == .int and (std.mem.endsWith(u8, f.name, "_id") or std.mem.eql(u8, f.name, "id"))) {
                try w.print("        if ({s} <= 0) return error.InvalidInput;\n", .{fid});
            }
        }
        for (ent.fields.items) |f| {
            if (!f.unique) continue;
            const fp = try pascalize(allocator, f.name);
            defer allocator.free(fp);
            const fid = try zigIdent(allocator, f.name);
            defer allocator.free(fid);
            const fn_name = try zigIdentCat(allocator, "findByUnique", fp, "");
            defer allocator.free(fn_name);
            try w.print("        if (try self.store.{s}({s}) != null) return error.Duplicate;\n", .{ fn_name, fid });
        }
        if (ent.unique_fields.len > 0) {
            try w.print("        if (try self.store.{s}(", .{en.find_unique_fn});
            for (ent.unique_fields, 0..) |uf, i| {
                if (i > 0) try w.writeAll(", ");
                const ufid = try zigIdent(allocator, uf);
                defer allocator.free(ufid);
                try w.writeAll(ufid);
            }
            try w.writeAll(") != null) return error.Duplicate;\n");
        }
        try w.writeAll("        // ── end ai-edit-zone ──────────────────────────────────────\n");
        try w.print("        return try self.store.{s}(", .{en.create_fn});
        for (ent.fields.items, 0..) |f, i| {
            if (i > 0) try w.writeAll(", ");
            const fid = try zigIdent(allocator, f.name);
            defer allocator.free(fid);
            try w.writeAll(fid);
        }
        try w.writeAll(");\n    }\n\n");

        // update + delete (no ai-edit-zone: keeps merge order stable when new
        // same-named zones would otherwise mispair with older files)
        try w.print("    pub fn {s}(self: *@This(), id: i64", .{en.update_fn});
        for (ent.fields.items) |f| {
            const fid = try zigIdent(allocator, f.name);
            defer allocator.free(fid);
            try w.print(", {s}: {s}", .{ fid, f.typ.zigType() });
        }
        try w.writeAll(") !void {\n");
        try w.writeAll("        if (id <= 0) return error.InvalidInput;\n");
        for (ent.fields.items) |f| {
            const fid = try zigIdent(allocator, f.name);
            defer allocator.free(fid);
            if (f.typ.isOwnedSlice()) {
                try w.print("        if ({s}.len == 0) return error.InvalidInput;\n", .{fid});
            }
        }
        try w.print("        return self.store.{s}(id", .{en.update_fn});
        for (ent.fields.items) |f| {
            const fid = try zigIdent(allocator, f.name);
            defer allocator.free(fid);
            try w.print(", {s}", .{fid});
        }
        try w.writeAll(");\n    }\n\n");

        try w.print("    pub fn {s}(self: *@This(), id: i64) !void {{\n", .{en.delete_fn});
        try w.writeAll("        if (id <= 0) return error.InvalidInput;\n");
        try w.print("        return self.store.{s}(id);\n    }}\n\n", .{en.delete_fn});

        if (ent.list_by) |lb| {
            const lb_pascal = try pascalize(allocator, lb);
            defer allocator.free(lb_pascal);
            const lb_ident = try zigIdent(allocator, lb);
            defer allocator.free(lb_ident);
            const list_fn = try listByFn(allocator, ent.name, lb_pascal);
            defer allocator.free(list_fn);
            try w.print("    pub fn {s}(self: *@This(), {s}: i64, page: usize, size: usize) !persist.{s}.{s} {{\n", .{
                en.list_fn, lb_ident, store_name, en.page,
            });
            try w.print("        if ({s} <= 0) return error.InvalidInput;\n", .{lb_ident});
            try w.print("        return try self.store.{s}({s}, page, size);\n", .{ list_fn, lb_ident });
            try w.writeAll("    }\n\n");
            try w.print("    pub fn {s}(self: *@This(), rows: []persist.{s}.{s}) void {{\n", .{
                en.free_fn, store_name, en.row,
            });
            try w.print("        self.store.{s}(rows);\n    }}\n\n", .{en.free_fn});
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

    var name_arena = std.heap.ArenaAllocator.init(allocator);
    defer name_arena.deinit();
    const na = name_arena.allocator();
    const svc_name = (try moduleNames(na, schema.module)).service;

    try w.writeAll("// @generated by `zf crud:zent` — AI: edit inside ai-edit-zone only.\n");
    try w.writeAll("const std = @import(\"std\");\nconst zfinal = @import(\"zfinal\");\nconst service = @import(\"service.zig\");\n\n");
    try w.print("pub var g_svc: ?*service.{s} = null;\n\n", .{svc_name});
    try w.print("fn svcOrErr(ctx: *zfinal.Context) !*service.{s} {{\n", .{svc_name});
    try w.writeAll("    _ = ctx;\n    return g_svc orelse error.ServiceNotReady;\n}\n\n");
    // Routes live in routes.zig / actions.zig (smart_routing) — handlers only below.

    var name_buf: [128]u8 = undefined;
    for (schema.entities.items) |ent| {
        const en = try entityNames(na, ent, ent.clientName(&name_buf));

        try w.print("pub fn {s}(ctx: *zfinal.Context) !void {{\n", .{en.create_fn});
        try w.writeAll("    const svc = try svcOrErr(ctx);\n");
        try w.writeAll("    // ── ai-edit-zone: handler hooks ───────────────────────────────\n");
        for (ent.fields.items) |f| {
            const fid = try zigIdent(allocator, f.name);
            defer allocator.free(fid);
            if (f.typ.isOwnedSlice()) {
                try w.print("    const {s} = try ctx.getPara(\"{s}\") orelse {{\n", .{ fid, try zigStr(na, f.name) });
                try w.print("        try ctx.renderJson(.{{ .ok = false, .error_msg = \"Missing {s}\" }});\n", .{try zigStr(na, f.name)});
                try w.writeAll("        return;\n    };\n");
            } else if (f.typ == .int or f.typ == .time) {
                if (f.default_value) |dv| {
                    try w.print("    const {s} = try ctx.getParaToLongDefault(\"{s}\", {s});\n", .{ fid, try zigStr(na, f.name), dv });
                } else {
                    try w.print("    const {s} = try ctx.getParaToLong(\"{s}\") orelse {{\n", .{ fid, try zigStr(na, f.name) });
                    try w.print("        try ctx.renderJson(.{{ .ok = false, .error_msg = \"Missing {s}\" }});\n", .{try zigStr(na, f.name)});
                    try w.writeAll("        return;\n    };\n");
                }
            } else if (f.typ == .bool) {
                const raw_ident = try zigIdentCat(allocator, "", f.name, "_raw");
                defer allocator.free(raw_ident);
                try w.print("    const {s} = try ctx.getPara(\"{s}\");\n", .{ raw_ident, try zigStr(na, f.name) });
                try w.print("    const {s} = if ({s}) |v| std.mem.eql(u8, v, \"true\") or std.mem.eql(u8, v, \"1\") else false;\n", .{ fid, raw_ident });
            } else {
                try w.print("    const {s} = try ctx.getParaToLongDefault(\"{s}\", 0);\n", .{ fid, try zigStr(na, f.name) });
            }
        }
        try w.writeAll("    // ── end ai-edit-zone ──────────────────────────────────────────\n");
        try w.print("    const id = svc.{s}(", .{en.create_fn});
        for (ent.fields.items, 0..) |f, i| {
            if (i > 0) try w.writeAll(", ");
            const fid = try zigIdent(allocator, f.name);
            defer allocator.free(fid);
            try w.writeAll(fid);
        }
        try w.writeAll(") catch |err| {\n");
        try w.writeAll("        try ctx.renderJson(.{ .ok = false, .error_msg = @errorName(err) });\n");
        try w.writeAll("        return;\n    };\n");
        try w.writeAll("    try ctx.renderJson(.{ .ok = true, .id = id });\n}\n\n");

        // update handler (id via query param; field parsing mirrors create,
        // generated outside ai-edit-zone to keep merge order stable)
        try w.print("pub fn {s}(ctx: *zfinal.Context) !void {{\n", .{en.update_fn});
        try w.writeAll("    const svc = try svcOrErr(ctx);\n");
        try w.writeAll("    const id = try ctx.getParaToLong(\"id\") orelse {\n");
        try w.writeAll("        try ctx.renderJson(.{ .ok = false, .error_msg = \"Missing id\" });\n");
        try w.writeAll("        return;\n    };\n");
        for (ent.fields.items) |f| {
            const fid = try zigIdent(allocator, f.name);
            defer allocator.free(fid);
            if (f.typ.isOwnedSlice()) {
                try w.print("    const {s} = try ctx.getPara(\"{s}\") orelse {{\n", .{ fid, try zigStr(na, f.name) });
                try w.print("        try ctx.renderJson(.{{ .ok = false, .error_msg = \"Missing {s}\" }});\n", .{try zigStr(na, f.name)});
                try w.writeAll("        return;\n    };\n");
            } else if (f.typ == .int or f.typ == .time) {
                if (f.default_value) |dv| {
                    try w.print("    const {s} = try ctx.getParaToLongDefault(\"{s}\", {s});\n", .{ fid, try zigStr(na, f.name), dv });
                } else {
                    try w.print("    const {s} = try ctx.getParaToLong(\"{s}\") orelse {{\n", .{ fid, try zigStr(na, f.name) });
                    try w.print("        try ctx.renderJson(.{{ .ok = false, .error_msg = \"Missing {s}\" }});\n", .{try zigStr(na, f.name)});
                    try w.writeAll("        return;\n    };\n");
                }
            } else if (f.typ == .bool) {
                const raw_ident = try zigIdentCat(allocator, "", f.name, "_raw");
                defer allocator.free(raw_ident);
                try w.print("    const {s} = try ctx.getPara(\"{s}\");\n", .{ raw_ident, try zigStr(na, f.name) });
                try w.print("    const {s} = if ({s}) |v| std.mem.eql(u8, v, \"true\") or std.mem.eql(u8, v, \"1\") else false;\n", .{ fid, raw_ident });
            } else {
                try w.print("    const {s} = try ctx.getParaToLongDefault(\"{s}\", 0);\n", .{ fid, try zigStr(na, f.name) });
            }
        }
        try w.print("    svc.{s}(id", .{en.update_fn});
        for (ent.fields.items) |f| {
            const fid = try zigIdent(allocator, f.name);
            defer allocator.free(fid);
            try w.print(", {s}", .{fid});
        }
        try w.writeAll(") catch |err| {\n");
        try w.writeAll("        try ctx.renderJson(.{ .ok = false, .error_msg = @errorName(err) });\n");
        try w.writeAll("        return;\n    };\n");
        try w.writeAll("    try ctx.renderJson(.{ .ok = true });\n}\n\n");

        // delete handler
        try w.print("pub fn {s}(ctx: *zfinal.Context) !void {{\n", .{en.delete_fn});
        try w.writeAll("    const svc = try svcOrErr(ctx);\n");
        try w.writeAll("    const id = try ctx.getParaToLong(\"id\") orelse {\n");
        try w.writeAll("        try ctx.renderJson(.{ .ok = false, .error_msg = \"Missing id\" });\n");
        try w.writeAll("        return;\n    };\n");
        try w.print("    svc.{s}(id) catch |err| {{\n", .{en.delete_fn});
        try w.writeAll("        try ctx.renderJson(.{ .ok = false, .error_msg = @errorName(err) });\n");
        try w.writeAll("        return;\n    };\n");
        try w.writeAll("    try ctx.renderJson(.{ .ok = true });\n}\n\n");

        if (ent.list_by) |lb| {
            const cname = ent.clientName(&name_buf);
            const plural = try pluralize(allocator, cname);
            defer allocator.free(plural);
            const lb_ident = try zigIdent(allocator, lb);
            defer allocator.free(lb_ident);
            try w.print("pub fn {s}(ctx: *zfinal.Context) !void {{\n", .{en.list_fn});
            try w.writeAll("    const svc = try svcOrErr(ctx);\n");
            try w.print("    const {s} = try ctx.getParaToLong(\"{s}\") orelse {{\n", .{ lb_ident, try zigStr(na, lb) });
            try w.print("        try ctx.renderJson(.{{ .ok = false, .error_msg = \"Missing {s}\" }});\n", .{try zigStr(na, lb)});
            try w.writeAll("        return;\n    };\n");
            try w.writeAll("    const page: usize = @intCast(try ctx.getParaToLongDefault(\"page\", 1));\n");
            try w.writeAll("    const size: usize = @intCast(try ctx.getParaToLongDefault(\"size\", 0)); // 0 = all\n");
            try w.print("    const pageresult = svc.{s}({s}, page, size) catch |err| {{\n", .{ en.list_fn, lb_ident });
            try w.writeAll("        try ctx.renderJson(.{ .ok = false, .error_msg = @errorName(err) });\n");
            try w.writeAll("        return;\n    };\n");
            try w.print("    defer svc.{s}(pageresult.rows);\n", .{en.free_fn});
            try w.print("    try ctx.renderJson(.{{ .ok = true, .{s} = pageresult.rows, .meta = .{{ .total = pageresult.total, .page = page, .size = size }} }});\n}}\n\n", .{try zigIdent(na, plural)});
        }
    }

    try w.writeAll(
        \\
        \\// ── ai-edit-zone: extra handlers ─────────────────────────
        \\// ── end ai-edit-zone ─────────────────────────────────────
        \\
    );
    return try aw.toOwnedSlice();
}

pub fn generateRoutes(allocator: std.mem.Allocator, schema: *const Schema) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    var name_arena = std.heap.ArenaAllocator.init(allocator);
    defer name_arena.deinit();
    const na = name_arena.allocator();
    try w.writeAll("// @generated by zf routes — DO NOT EDIT\n");
    try w.writeAll("// Regenerate: zf routes  (or: zf crud:zent)\n");
    try w.writeAll("const handler = @import(\"handler.zig\");\n\n");
    try w.writeAll("pub fn register(app: anytype) !void {\n");
    var name_buf: [128]u8 = undefined;
    for (schema.entities.items) |ent| {
        const cname = ent.clientName(&name_buf);
        const en = try entityNames(na, ent, cname);
        const plural = try pluralize(allocator, cname);
        defer allocator.free(plural);
        const base = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ schema.api_prefix, plural });
        defer allocator.free(base);
        // Normalize double slash if api_prefix empty
        const path = if (schema.api_prefix.len == 0)
            try std.fmt.allocPrint(allocator, "/{s}", .{plural})
        else
            try allocator.dupe(u8, base);
        defer allocator.free(path);
        try w.print("    try app.post(\"{s}\", handler.{s});\n", .{ try zigStr(na, path), en.create_fn });
        try w.print("    try app.put(\"{s}\", handler.{s});\n", .{ try zigStr(na, path), en.update_fn });
        try w.print("    try app.delete(\"{s}\", handler.{s});\n", .{ try zigStr(na, path), en.delete_fn });
        if (ent.list_by != null) {
            try w.print("    try app.get(\"{s}\", handler.{s});\n", .{ try zigStr(na, path), en.list_fn });
        }
    }
    try w.writeAll("}\n");
    return try aw.toOwnedSlice();
}

/// Emit actions.zig for zent modules (smart_routing true source).
pub fn generateActions(allocator: std.mem.Allocator, schema: *const Schema) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    var name_arena = std.heap.ArenaAllocator.init(allocator);
    defer name_arena.deinit();
    const na = name_arena.allocator();
    try w.writeAll("// @generated by zf crud:zent — AI: edit actions table; then `zf routes`\n");
    try w.writeAll("const handler = @import(\"handler.zig\");\n\n");
    try w.print("pub const module = .{{\n    .name = \"{s}\",\n    .prefix = \"{s}\",\n}};\n\n", .{ try zigStr(na, schema.module), try zigStr(na, schema.api_prefix) });
    try w.writeAll("pub const actions = .{\n");
    var name_buf: [128]u8 = undefined;
    for (schema.entities.items) |ent| {
        const cname = ent.clientName(&name_buf);
        const en = try entityNames(na, ent, cname);
        const plural = try pluralize(allocator, cname);
        defer allocator.free(plural);
        const path = if (schema.api_prefix.len == 0)
            try std.fmt.allocPrint(allocator, "/{s}", .{plural})
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ schema.api_prefix, plural });
        defer allocator.free(path);
        const ename = try zigStr(na, ent.name);
        const epath = try zigStr(na, path);
        try w.print("    .{{ .name = \"create{s}\", .method = .POST, .action_key = \"{s}\", .handler = handler.{s} }},\n", .{ ename, epath, en.create_fn });
        try w.print("    .{{ .name = \"update{s}\", .method = .PUT, .action_key = \"{s}\", .handler = handler.{s} }},\n", .{ ename, epath, en.update_fn });
        try w.print("    .{{ .name = \"delete{s}\", .method = .DELETE, .action_key = \"{s}\", .handler = handler.{s} }},\n", .{ ename, epath, en.delete_fn });
        if (ent.list_by != null) {
            try w.print("    .{{ .name = \"list{s}\", .method = .GET, .action_key = \"{s}\", .handler = handler.{s} }},\n", .{ ename, epath, en.list_fn });
        }
    }
    try w.writeAll(
        \\    // ── ai-edit-zone: extra actions ───────────────────────────────
        \\    // ── end ai-edit-zone ──────────────────────────────────────────
        \\};
        \\
    );
    return try aw.toOwnedSlice();
}

pub fn generateBootstrapSnippet(allocator: std.mem.Allocator, schema: *const Schema) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    var name_arena = std.heap.ArenaAllocator.init(allocator);
    defer name_arena.deinit();
    const na = name_arena.allocator();
    const mn = try moduleNames(na, schema.module);
    const mod = try zigStr(na, schema.module);

    try w.writeAll("// ── paste into main.zig (zent primary data layer) ──\n");
    try w.writeAll("const zfinal = @import(\"zfinal\");\nconst zent = zfinal.zent;\n");
    try w.print("const persist = @import(\"modules/{s}/persistence.zig\");\n", .{mod});
    try w.print("const service = @import(\"modules/{s}/service.zig\");\n", .{mod});
    try w.print("const handler = @import(\"modules/{s}/handler.zig\");\n", .{mod});
    try w.print("const routes = @import(\"modules/{s}/routes.zig\");\n\n", .{mod});
    try w.writeAll("var drv = try zent.sql_sqlite.SQLiteDriver.open(allocator, \"app.db\");\ndefer drv.close();\n");
    try w.writeAll("try zent.sql_schema.migrateSchema(allocator, drv.asDriver(), persist.infos);\n");
    try w.print("var store = persist.{s}.init(allocator, drv.asDriver());\n", .{mn.store});
    try w.print("var svc = service.{s}.init(&store);\n", .{mn.service});
    try w.writeAll("handler.g_svc = &svc;\ntry routes.register(&app);\n");
    return try aw.toOwnedSlice();
}

pub fn emitJsonManifest(allocator: std.mem.Allocator, schema_path: []const u8, schema: *const Schema) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    var name_arena = std.heap.ArenaAllocator.init(allocator);
    defer name_arena.deinit();
    const na = name_arena.allocator();

    const fw_ver = @import("zfinal_version");
    const mod_json = try jsonStr(na, schema.module);
    try w.writeAll("{\n  \"$schema\": \"https://zfinal.dev/schemas/zent-manifest-1.json\",\n");
    try w.print("  \"version\": \"{s}\",\n  \"generator\": \"zf crud:zent\",\n", .{fw_ver.semver});
    try w.print("  \"schema_path\": \"{s}\",\n", .{try jsonStr(na, schema_path)});
    try w.print("  \"module\": \"{s}\",\n", .{mod_json});
    try w.print("  \"api_prefix\": \"{s}\",\n", .{try jsonStr(na, schema.api_prefix)});
    try w.writeAll("  \"data_layer\": \"zent\",\n");
    try w.writeAll("  \"ai_primary\": true,\n");
    try w.writeAll("  \"files\": {\n");
    try w.print("    \"model\": \"src/modules/{s}/model.zig\",\n", .{mod_json});
    try w.print("    \"persistence\": \"src/modules/{s}/persistence.zig\",\n", .{mod_json});
    try w.print("    \"service\": \"src/modules/{s}/service.zig\",\n", .{mod_json});
    try w.print("    \"handler\": \"src/modules/{s}/handler.zig\",\n", .{mod_json});
    try w.print("    \"actions\": \"src/modules/{s}/actions.zig\",\n", .{mod_json});
    try w.print("    \"routes\": \"src/modules/{s}/routes.zig\"\n", .{mod_json});
    try w.writeAll("  },\n  \"ai_edit_zones\": [\n");
    try w.writeAll("    { \"file\": \"model.zig\", \"markers\": [\"// ── ai-edit-zone: model hooks\"], \"purpose\": \"edges, privacy, extra Schema\" },\n");
    try w.writeAll("    { \"file\": \"persistence.zig\", \"markers\": [\"// ── ai-edit-zone: custom queries\"], \"purpose\": \"domain queries, joins, aggregates\" },\n");
    try w.writeAll("    { \"file\": \"service.zig\", \"markers\": [\"// ── ai-edit-zone: business rules\", \"// ── ai-edit-zone: extra service methods\"], \"purpose\": \"validation, orchestration\" },\n");
    try w.writeAll("    { \"file\": \"handler.zig\", \"markers\": [\"// ── ai-edit-zone: handler hooks\", \"// ── ai-edit-zone: extra handlers\"], \"purpose\": \"auth, response shaping, custom handlers\" },\n");
    try w.writeAll("    { \"file\": \"actions.zig\", \"markers\": [\"// ── ai-edit-zone: extra actions\"], \"purpose\": \"custom routes; run zf routes\" }\n");
    try w.writeAll("  ],\n  \"entities\": [\n");
    for (schema.entities.items, 0..) |ent, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.writeAll("    {\n");
        try w.print("      \"name\": \"{s}\"", .{try jsonStr(na, ent.name)});
        if (ent.list_by) |lb| try w.print(",\n      \"list_by\": \"{s}\"", .{try jsonStr(na, lb)});
        try w.writeAll(",\n      \"fields\": [\n");
        for (ent.fields.items, 0..) |f, fi| {
            if (fi > 0) try w.writeAll(",\n");
            try w.print("        {{\"name\": \"{s}\", \"type\": \"{s}\"", .{ try jsonStr(na, f.name), @tagName(f.typ) });
            if (f.indexed) try w.writeAll(", \"index\": true");
            if (f.unique) try w.writeAll(", \"unique\": true");
            if (f.sensitive) try w.writeAll(", \"sensitive\": true");
            if (f.required) try w.writeAll(", \"required\": true");
            if (f.email) try w.writeAll(", \"email\": true");
            if (f.positive) try w.writeAll(", \"positive\": true");
            try w.writeAll("}");
        }
        try w.writeAll("\n      ]");
        if (ent.refs.items.len > 0) {
            try w.writeAll(",\n      \"refs\": [");
            for (ent.refs.items, 0..) |r, ri| {
                if (ri > 0) try w.writeAll(",");
                try w.print("{{\"name\": \"{s}\", \"target\": \"{s}\", \"field\": \"{s}\"}}", .{ try jsonStr(na, r.name), try jsonStr(na, r.target), try jsonStr(na, r.field) });
            }
            try w.writeAll("]");
        }
        if (ent.unique_fields.len > 0) {
            try w.writeAll(",\n      \"unique_fields\": [");
            for (ent.unique_fields, 0..) |uf, ui| {
                if (ui > 0) try w.writeAll(",");
                try w.print("\"{s}\"", .{try jsonStr(na, uf)});
            }
            try w.writeAll("]");
        }
        try w.writeAll("\n    }");
    }
    try w.writeAll("\n  ],\n  \"next_steps\": [\n");
    try w.writeAll("    \"ALWAYS use --json and parse files + ai_edit_zones before editing\",\n");
    try w.writeAll("    \"Wire migrateSchema + Store + Service + routes.register in main.zig\",\n");
    try w.writeAll("    \"Edit ONLY inside // ── ai-edit-zone blocks — never rewrite generated Create/Query\",\n");
    try w.writeAll("    \"Add routes via actions.zig then `zf routes`; Do NOT mix zfinal.DB and zent.Driver in one Tx\",\n");
    try w.writeAll("    \"zf check && zig build test\"\n  ]\n}\n");
    return try aw.toOwnedSlice();
}
