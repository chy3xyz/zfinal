//! Minimal OpenAPI 3.0.3 spec generator for ZFinal projects.
//!
//! Scans Zig source files for static route registrations and renders an
//! OpenAPI YAML document covering:
//!   - `app.get/post/put/patch/delete("/path", ...)`
//!   - `app.getWithInterceptors/...` variants
//!   - `RouteGroup.init(&app, "/prefix")` + group `.get/post/...`
//!   - `pub const Name = struct { … }` → `components.schemas.Name` / `NameInput`
//!
//! Mutating ops get bearer JWT + `{Resource}Input` when a matching DTO exists.

const std = @import("std");

// ─────────────────────────────────────────────────────────────────────────────
// Public types
// ─────────────────────────────────────────────────────────────────────────────

/// HTTP method on a registered route. Declaration order is the canonical sort
/// key alongside path, matching OpenAPI convention (GET, POST, PUT, PATCH,
/// DELETE).
pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
};

/// A single (method, path) endpoint. `path` is owned by the Spec and already
/// normalized (`":id"` → `"{id}"`).
pub const Route = struct {
    method: HttpMethod,
    path: []const u8,
};

/// One property on a discovered DTO (from `model.zig` / ORM structs).
pub const DtoField = struct {
    name: []const u8,
    /// OpenAPI primitive: string | integer | number | boolean
    type_name: []const u8,
    nullable: bool = false,
};

/// Named JSON schema derived from Zig `pub const Name = struct { … }`.
pub const DtoSchema = struct {
    name: []const u8,
    fields: []DtoField,

    pub fn deinit(self: *DtoSchema, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.fields) |f| allocator.free(f.name);
        allocator.free(self.fields);
        self.* = undefined;
    }
};

/// Parsed OpenAPI spec. `routes` is sorted by (path, method) and deduped.
pub const Spec = struct {
    title: []const u8,
    version: []const u8,
    routes: std.ArrayList(Route),
    dtos: std.ArrayList(DtoSchema) = .empty,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Spec) void {
        for (self.routes.items) |r| self.allocator.free(r.path);
        self.routes.deinit(self.allocator);
        for (self.dtos.items) |*d| d.deinit(self.allocator);
        self.dtos.deinit(self.allocator);
        self.* = undefined;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Parser
// ─────────────────────────────────────────────────────────────────────────────

const method_names = [_][]const u8{
    "get",
    "post",
    "put",
    "patch",
    "delete",
    "getWithInterceptors",
    "postWithInterceptors",
    "putWithInterceptors",
    "patchWithInterceptors",
    "deleteWithInterceptors",
};

/// Parse `source` into a Spec. `source` is typically the concatenation of
/// `.zig` files in the project (each file's routes merge into the spec).
///
/// Pre-conditions baked into the design:
///   - `app` is implicitly a known registrar with empty prefix
///   - `var X = ...RouteGroup.init(&app, "/prefix")` adds X as a registrar
///
/// Lines that don't match any pattern are silently skipped (they may contain
/// comments, unrelated code, or doc strings).
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Spec {
    var spec = Spec{
        .title = "ZFinal API",
        .version = "0.1.0",
        .routes = std.ArrayList(Route).empty,
        .allocator = allocator,
    };
    errdefer spec.deinit();

    // Seed prefixes: `app` is always a route registrar with empty prefix.
    // Group vars are added when we see `var X = ... RouteGroup.init(...)`.
    // The values are heap-allocated; the `defer` block below frees them
    // before the hashmap structure is torn down.
    var prefixes = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = prefixes.iterator();
        while (it.next()) |entry| allocator.free(entry.value_ptr.*);
        prefixes.deinit();
    }
    try prefixes.put("app", "");

    // Two passes: first discover RouteGroup prefixes, then extract routes.
    // This is necessary because `api.get(...)` below the group declaration
    // depends on `api` being registered already.
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        _ = try collectGroupPrefix(allocator, line, &prefixes);
    }

    var lines2 = std.mem.splitScalar(u8, source, '\n');
    while (lines2.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (try collectRoute(allocator, line, &prefixes, &spec)) continue;
        _ = try collectActionKeyRoute(allocator, line, &spec);
    }

    dedupe(&spec);
    std.mem.sort(Route, spec.routes.items, {}, lessThanRoute);
    try collectDtosFromSource(allocator, source, &spec);

    return spec;
}

/// If `line` declares a `var X = ... RouteGroup.init(<app>, "<prefix>")`,
/// record `X -> prefix` in `prefixes`. Returns true if it matched.
fn collectGroupPrefix(
    allocator: std.mem.Allocator,
    line: []const u8,
    prefixes: *std.StringHashMap([]const u8),
) !bool {
    if (std.mem.indexOf(u8, line, "RouteGroup.init(") == null) return false;
    const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse return false;
    const lhs = std.mem.trim(u8, line[0..eq_pos], " \t");
    const var_name = extractVarName(lhs) orelse return false;
    const rhs = line[eq_pos + 1 ..];
    const prefix = extractFirstStringLiteral(allocator, rhs) orelse return false;
    errdefer allocator.free(prefix);
    // Free any prior prefix for this var to avoid leaks on repeated decls.
    if (prefixes.fetchRemove(var_name)) |kv| allocator.free(kv.value);
    errdefer if (prefixes.fetchRemove(var_name)) |kv2| allocator.free(kv2.value);
    try prefixes.put(var_name, prefix);
    return true;
}

/// If `line` is a `<var>.<method>("...", ...)` style route registration whose
/// receiver is a known registrar, append the normalized route to `spec`.
fn collectRoute(
    allocator: std.mem.Allocator,
    line: []const u8,
    prefixes: *const std.StringHashMap([]const u8),
    spec: *Spec,
) !bool {
    for (method_names) |mname| {
        const dot_pos = findMethodCall(line, mname) orelse continue;

        // Receiver identifier: scan backwards from `.` until non-ident char.
        var recv_start: usize = dot_pos;
        while (recv_start > 0 and isIdentChar(line[recv_start - 1])) {
            recv_start -= 1;
        }
        if (recv_start == dot_pos) continue; // no receiver
        const receiver = line[recv_start..dot_pos];

        const prefix = prefixes.get(receiver) orelse continue;

        // First string literal after the method call paren.
        const after_paren = dot_pos + 1 + mname.len + 1; // . + name + (
        const path_lit = extractFirstStringLiteral(allocator, line[after_paren..]) orelse continue;

        // Skip if not a path-shaped literal.
        if (path_lit.len == 0 or path_lit[0] != '/') {
            allocator.free(path_lit);
            continue;
        }

        const full_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, path_lit });
        allocator.free(path_lit);

        const normalized = try normalizePath(allocator, full_path);
        allocator.free(full_path);

        errdefer allocator.free(normalized);

        try spec.routes.append(allocator, .{
            .method = methodFromName(mname).?,
            .path = normalized,
        });
        return true;
    }
    return false;
}

/// Scan `actions.zig` lines: `.action_key = "/path"` (+ optional `.method = .GET`).
fn collectActionKeyRoute(allocator: std.mem.Allocator, line: []const u8, spec: *Spec) !bool {
    const key_pos = std.mem.indexOf(u8, line, ".action_key") orelse return false;
    const after = line[key_pos..];
    const path_lit = extractFirstStringLiteral(allocator, after) orelse return false;
    if (path_lit.len == 0 or path_lit[0] != '/') {
        allocator.free(path_lit);
        return false;
    }
    const method: HttpMethod = blk: {
        // Prefer method on the same line (actions table row)
        if (std.mem.indexOf(u8, line, ".method")) |mp| {
            const win = line[mp..@min(line.len, mp + 24)];
            if (std.mem.indexOf(u8, win, ".GET")) |_| break :blk .GET;
            if (std.mem.indexOf(u8, win, ".POST")) |_| break :blk .POST;
            if (std.mem.indexOf(u8, win, ".PUT")) |_| break :blk .PUT;
            if (std.mem.indexOf(u8, win, ".PATCH")) |_| break :blk .PATCH;
            if (std.mem.indexOf(u8, win, ".DELETE")) |_| break :blk .DELETE;
        }
        break :blk .POST;
    };
    const normalized = try normalizePath(allocator, path_lit);
    allocator.free(path_lit);
    errdefer allocator.free(normalized);
    try spec.routes.append(allocator, .{ .method = method, .path = normalized });
    return true;
}

/// Find the offset of `.<mname>(` in `line`. Accepts any match — downstream
/// the receiver is checked against the known registrar set, so unmatched
/// receivers (non-route methods like `.gets(...)`) are harmlessly skipped.
fn findMethodCall(line: []const u8, mname: []const u8) ?usize {
    // Build ".mname(" in a small buffer.
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, ".{s}(", .{mname}) catch return null;
    return std.mem.indexOf(u8, line, needle);
}

fn extractVarName(lhs: []const u8) ?[]const u8 {
    var idx: usize = 0;
    if (std.mem.startsWith(u8, lhs, "var ")) {
        idx = 4;
    } else if (std.mem.startsWith(u8, lhs, "const ")) {
        idx = 6;
    } else {
        return null;
    }
    while (idx < lhs.len and (lhs[idx] == ' ' or lhs[idx] == '\t')) : (idx += 1) {}
    const start = idx;
    while (idx < lhs.len and isIdentChar(lhs[idx])) : (idx += 1) {}
    if (start == idx) return null;
    return lhs[start..idx];
}

/// Find the first `"..."` string literal in `src`. Returns a heap-allocated
/// copy of the inner text. Returns null if none found or if a `//` comment
/// precedes any quote (we bail out to avoid capturing commented literals).
fn extractFirstStringLiteral(allocator: std.mem.Allocator, src: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] == '/' and i + 1 < src.len and src[i + 1] == '/') return null;
        if (src[i] == '"') {
            var j: usize = i + 1;
            while (j < src.len and src[j] != '"') {
                if (src[j] == '\\' and j + 1 < src.len) j += 1;
                j += 1;
            }
            if (j >= src.len) return null;
            return allocator.dupe(u8, src[i + 1 .. j]) catch null;
        }
    }
    return null;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

/// Normalize a path: each `:name` segment becomes `{name}` (OpenAPI syntax).
/// Preserves leading/trailing slashes by walking splitScalar segments.
fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var parts = std.mem.splitScalar(u8, path, '/');
    var first = true;
    while (parts.next()) |part| {
        if (!first) try out.append(allocator, '/');
        first = false;
        if (part.len > 0 and part[0] == ':') {
            try out.append(allocator, '{');
            try out.appendSlice(allocator, part[1..]);
            try out.append(allocator, '}');
        } else {
            try out.appendSlice(allocator, part);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn methodFromName(name: []const u8) ?HttpMethod {
    if (std.mem.eql(u8, name, "get") or std.mem.eql(u8, name, "getWithInterceptors"))
        return .GET;
    if (std.mem.eql(u8, name, "post") or std.mem.eql(u8, name, "postWithInterceptors"))
        return .POST;
    if (std.mem.eql(u8, name, "put") or std.mem.eql(u8, name, "putWithInterceptors"))
        return .PUT;
    if (std.mem.eql(u8, name, "patch") or std.mem.eql(u8, name, "patchWithInterceptors"))
        return .PATCH;
    if (std.mem.eql(u8, name, "delete") or std.mem.eql(u8, name, "deleteWithInterceptors"))
        return .DELETE;
    return null;
}

/// Remove duplicate (method, path) pairs. Keeps first occurrence.
///
/// NOTE: Zig 0.17's `StringHashMap.getOrPut` stores the key by fat-pointer
/// (slice) — NOT a copy of the bytes. So we cannot free the key buffer
/// after insertion without corrupting the hashmap. We therefore keep the
/// keys alive in a sibling `ArrayList` and free them only after `seen` is
/// torn down (defer LIFO order).
fn dedupe(spec: *Spec) void {
    var seen = std.StringHashMap(void).init(spec.allocator);
    defer seen.deinit();
    var keys = std.ArrayList([]const u8).empty;
    defer {
        for (keys.items) |k| spec.allocator.free(k);
        keys.deinit(spec.allocator);
    }

    var i: usize = 0;
    while (i < spec.routes.items.len) {
        const key = std.fmt.allocPrint(
            spec.allocator,
            "{s}|{s}",
            .{ @tagName(spec.routes.items[i].method), spec.routes.items[i].path },
        ) catch {
            i += 1;
            continue;
        };
        const gop = seen.getOrPut(key) catch {
            spec.allocator.free(key);
            i += 1;
            continue;
        };
        if (gop.found_existing) {
            // Key already present — free our redundant copy and drop the route.
            spec.allocator.free(key);
            spec.allocator.free(spec.routes.items[i].path);
            _ = spec.routes.orderedRemove(i);
        } else {
            // Hashmap now references this key. Hand ownership to `keys` so
            // the buffer outlives `seen`.
            keys.append(spec.allocator, key) catch {
                i += 1;
                continue;
            };
            i += 1;
        }
    }
}

fn lessThanRoute(_: void, a: Route, b: Route) bool {
    if (std.mem.lessThan(u8, a.path, b.path)) return true;
    if (!std.mem.eql(u8, a.path, b.path)) return false;
    // Declaration order on HttpMethod = GET, POST, PUT, PATCH, DELETE.
    return @intFromEnum(a.method) < @intFromEnum(b.method);
}

// ─────────────────────────────────────────────────────────────────────────────
// DTO discovery (field-level schemas from Zig ORM structs)
// ─────────────────────────────────────────────────────────────────────────────

const skip_dto_names = [_][]const u8{ "Data", "Self", "T", "Error", "Config", "Options", "Bag", "Entry" };

fn shouldSkipDtoName(name: []const u8) bool {
    for (skip_dto_names) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

fn zigTypeToOpenApi(zt: []const u8) struct { type_name: []const u8, nullable: bool } {
    var t = std.mem.trim(u8, zt, " \t");
    var nullable = false;
    if (t.len > 0 and t[0] == '?') {
        nullable = true;
        t = t[1..];
    }
    if (std.mem.eql(u8, t, "bool")) return .{ .type_name = "boolean", .nullable = nullable };
    if (std.mem.startsWith(u8, t, "i") or std.mem.startsWith(u8, t, "u")) {
        if (std.mem.indexOfScalar(u8, t, '[') == null)
            return .{ .type_name = "integer", .nullable = nullable };
    }
    if (std.mem.startsWith(u8, t, "f32") or std.mem.startsWith(u8, t, "f64"))
        return .{ .type_name = "number", .nullable = nullable };
    return .{ .type_name = "string", .nullable = nullable };
}

/// Scan `source` for `pub const Name = struct { field: Type, … }` and fill `spec.dtos`.
pub fn collectDtosFromSource(allocator: std.mem.Allocator, source: []const u8, spec: *Spec) !void {
    try collectStructDtosFromSource(allocator, source, spec);
    try collectZentDtosFromSource(allocator, source, spec);
}

fn dtoExists(spec: *const Spec, name: []const u8) bool {
    for (spec.dtos.items) |d| {
        if (std.mem.eql(u8, d.name, name)) return true;
    }
    return false;
}

fn appendDtoIfNew(allocator: std.mem.Allocator, spec: *Spec, name: []const u8, fields: *std.ArrayList(DtoField)) !void {
    if (fields.items.len == 0) {
        fields.deinit(allocator);
        return;
    }
    if (dtoExists(spec, name)) {
        for (fields.items) |f| allocator.free(f.name);
        fields.deinit(allocator);
        return;
    }
    try spec.dtos.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .fields = try fields.toOwnedSlice(allocator),
    });
}

fn collectStructDtosFromSource(allocator: std.mem.Allocator, source: []const u8, spec: *Spec) !void {
    var i: usize = 0;
    while (i < source.len) {
        const rest = source[i..];
        const marker = "pub const ";
        const mpos = std.mem.indexOf(u8, rest, marker) orelse break;
        i += mpos + marker.len;
        const after = source[i..];
        const name_end = std.mem.indexOfAny(u8, after, " \t=") orelse continue;
        const name = std.mem.trim(u8, after[0..name_end], " \t");
        if (name.len == 0 or name[0] < 'A' or name[0] > 'Z') continue;
        if (shouldSkipDtoName(name)) continue;

        const eq = std.mem.indexOf(u8, after, "= struct") orelse continue;
        // Avoid matching far-away structs: require "= struct" soon after name.
        if (eq > name_end + 24) continue;
        const brace = std.mem.indexOfScalar(u8, after[eq..], '{') orelse continue;
        const body_start = eq + brace + 1;
        var depth: i32 = 1;
        var j = body_start;
        while (j < after.len and depth > 0) : (j += 1) {
            if (after[j] == '{') depth += 1;
            if (after[j] == '}') depth -= 1;
        }
        if (depth != 0) continue;
        const body = after[body_start .. j - 1];

        var fields = std.ArrayList(DtoField).empty;
        errdefer {
            for (fields.items) |f| allocator.free(f.name);
            fields.deinit(allocator);
        }
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '/' or line[0] == '#') continue;
            if (std.mem.startsWith(u8, line, "pub ") or std.mem.startsWith(u8, line, "const ") or
                std.mem.startsWith(u8, line, "fn ") or std.mem.startsWith(u8, line, "comptime"))
                continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const fname = std.mem.trim(u8, line[0..colon], " \t");
            if (fname.len == 0 or !std.ascii.isAlphabetic(fname[0])) continue;
            var type_part = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.mem.indexOfScalar(u8, type_part, ',')) |c| type_part = std.mem.trim(u8, type_part[0..c], " \t");
            if (std.mem.indexOfScalar(u8, type_part, '=')) |e| type_part = std.mem.trim(u8, type_part[0..e], " \t");
            if (type_part.len == 0) continue;
            const mapped = zigTypeToOpenApi(type_part);
            const owned_name = try allocator.dupe(u8, fname);
            errdefer allocator.free(owned_name);
            try fields.append(allocator, .{
                .name = owned_name,
                .type_name = mapped.type_name,
                .nullable = mapped.nullable,
            });
        }
        try appendDtoIfNew(allocator, spec, name, &fields);
    }
}

fn zentFieldOpenApiType(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "Int") or std.mem.eql(u8, kind, "Uint")) return "integer";
    if (std.mem.eql(u8, kind, "Float") or std.mem.eql(u8, kind, "Decimal")) return "number";
    if (std.mem.eql(u8, kind, "Bool") or std.mem.eql(u8, kind, "Boolean")) return "boolean";
    return "string"; // String, Text, DateTime, UUID, …
}

/// Parse zent `Schema("Name", .{ .fields = &.{ field.String("x"), … } })`.
pub fn collectZentDtosFromSource(allocator: std.mem.Allocator, source: []const u8, spec: *Spec) !void {
    var i: usize = 0;
    while (i < source.len) {
        const rest = source[i..];
        const marker = "Schema(\"";
        const mpos = std.mem.indexOf(u8, rest, marker) orelse break;
        i += mpos + marker.len;
        const after = source[i..];
        const qend = std.mem.indexOfScalar(u8, after, '"') orelse continue;
        const name = after[0..qend];
        if (name.len == 0 or shouldSkipDtoName(name)) continue;

        // Find `.fields = &.{` within a reasonable window after Schema("Name"
        const window_end = @min(after.len, qend + 800);
        const window = after[0..window_end];
        const fields_key = std.mem.indexOf(u8, window, ".fields") orelse continue;
        const amp = std.mem.indexOf(u8, window[fields_key..], ".{") orelse
            std.mem.indexOf(u8, window[fields_key..], "&[") orelse continue;
        var body_start = fields_key + amp;
        // skip to after `.{` or `&.{`
        if (std.mem.indexOf(u8, window[body_start..], "{")) |br| {
            body_start = body_start + br + 1;
        } else continue;

        var depth: i32 = 1;
        var j = body_start;
        while (j < window.len and depth > 0) : (j += 1) {
            if (window[j] == '{') depth += 1;
            if (window[j] == '}') depth -= 1;
        }
        if (depth != 0) continue;
        const body = window[body_start .. j - 1];

        var fields = std.ArrayList(DtoField).empty;
        errdefer {
            for (fields.items) |f| allocator.free(f.name);
            fields.deinit(allocator);
        }

        // Match field.Kind("name") occurrences
        var bi: usize = 0;
        while (bi < body.len) {
            const chunk = body[bi..];
            const fpos = std.mem.indexOf(u8, chunk, "field.") orelse break;
            bi += fpos + "field.".len;
            const kind_rest = body[bi..];
            const kind_end = std.mem.indexOfAny(u8, kind_rest, "(\t ") orelse continue;
            const kind = kind_rest[0..kind_end];
            const paren = std.mem.indexOfScalar(u8, kind_rest, '(') orelse continue;
            const after_paren = kind_rest[paren + 1 ..];
            const lit = std.mem.indexOfScalar(u8, after_paren, '"') orelse continue;
            const lit_rest = after_paren[lit + 1 ..];
            const lit_end = std.mem.indexOfScalar(u8, lit_rest, '"') orelse continue;
            const fname = lit_rest[0..lit_end];
            if (fname.len == 0) continue;
            const owned = try allocator.dupe(u8, fname);
            errdefer allocator.free(owned);
            try fields.append(allocator, .{
                .name = owned,
                .type_name = zentFieldOpenApiType(kind),
                .nullable = false,
            });
            bi += paren + 1 + lit + 1 + lit_end;
        }
        try appendDtoIfNew(allocator, spec, name, &fields);
    }
}

/// Last non-`{param}` path segment, PascalCased singular (users → User).
fn dtoNameForPath(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    var last: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (seg[0] == '{') continue;
        last = seg;
    }
    const seg = last orelse return null;
    if (std.mem.eql(u8, seg, "api") or std.mem.eql(u8, seg, "health") or std.mem.eql(u8, seg, "metrics"))
        return null;

    var base = seg;
    if (base.len > 1 and base[base.len - 1] == 's' and !std.mem.endsWith(u8, base, "ss"))
        base = base[0 .. base.len - 1];

    var buf = try allocator.alloc(u8, base.len);
    @memcpy(buf, base);
    buf[0] = std.ascii.toUpper(buf[0]);
    var i: usize = 1;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == '_' or buf[i] == '-') {
            // drop separator and upper next
            if (i + 1 < buf.len) buf[i + 1] = std.ascii.toUpper(buf[i + 1]);
        }
    }
    // Remove _ and -
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (buf) |c| {
        if (c == '_' or c == '-') continue;
        try out.append(allocator, c);
    }
    allocator.free(buf);
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(allocator);
}

fn findDto(spec: Spec, name: []const u8) ?*const DtoSchema {
    for (spec.dtos.items) |*d| {
        if (std.mem.eql(u8, d.name, name)) return d;
    }
    return null;
}

fn appendDtoSchema(allocator: std.mem.Allocator, out: *std.ArrayList(u8), dto: DtoSchema, suffix: []const u8) !void {
    try appendIndented(allocator, out, 2, "");
    try out.appendSlice(allocator, dto.name);
    try out.appendSlice(allocator, suffix);
    try out.appendSlice(allocator, ":\n");
    try appendIndented(allocator, out, 3, "type: object\n");
    try appendIndented(allocator, out, 3, "properties:\n");
    for (dto.fields) |f| {
        if (suffix.len > 0 and std.mem.eql(u8, f.name, "id")) continue; // Input omits id
        try appendIndented(allocator, out, 4, "");
        try out.appendSlice(allocator, f.name);
        try out.appendSlice(allocator, ":\n");
        try appendIndented(allocator, out, 5, "type: ");
        try out.appendSlice(allocator, f.type_name);
        try out.append(allocator, '\n');
        if (f.nullable) {
            try appendIndented(allocator, out, 5, "nullable: true\n");
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// YAML renderer
// ─────────────────────────────────────────────────────────────────────────────

/// Render `spec` as an OpenAPI 3.0.3 YAML document.
///
/// Each operation has path parameters, standard responses, and (for POST/PUT/PATCH)
/// a JSON request body (`{Resource}Input` when a matching DTO exists). Mutating
/// operations declare `bearerAuth` security. Deterministic: same spec → same bytes.
pub fn renderYaml(allocator: std.mem.Allocator, spec: Spec) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "openapi: 3.0.3\n");
    try out.appendSlice(allocator, "info:\n");
    try appendIndented(allocator, &out, 1, "title: ");
    try out.appendSlice(allocator, spec.title);
    try out.append(allocator, '\n');
    try appendIndented(allocator, &out, 1, "version: ");
    try out.appendSlice(allocator, spec.version);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, "components:\n");
    try appendIndented(allocator, &out, 1, "securitySchemes:\n");
    try appendIndented(allocator, &out, 2, "bearerAuth:\n");
    try appendIndented(allocator, &out, 3, "type: http\n");
    try appendIndented(allocator, &out, 3, "scheme: bearer\n");
    try appendIndented(allocator, &out, 3, "bearerFormat: JWT\n");
    try appendIndented(allocator, &out, 1, "schemas:\n");
    try appendIndented(allocator, &out, 2, "HttpError:\n");
    try appendIndented(allocator, &out, 3, "type: object\n");
    try appendIndented(allocator, &out, 3, "required: [err, msg]\n");
    try appendIndented(allocator, &out, 3, "properties:\n");
    try appendIndented(allocator, &out, 4, "err:\n");
    try appendIndented(allocator, &out, 5, "type: string\n");
    try appendIndented(allocator, &out, 5, "description: machine code (bad_request, unauthorized, ...)\n");
    try appendIndented(allocator, &out, 4, "msg:\n");
    try appendIndented(allocator, &out, 5, "type: string\n");
    try appendIndented(allocator, &out, 4, "detail:\n");
    try appendIndented(allocator, &out, 5, "type: string\n");
    try appendIndented(allocator, &out, 2, "JsonObject:\n");
    try appendIndented(allocator, &out, 3, "type: object\n");
    try appendIndented(allocator, &out, 3, "additionalProperties: true\n");
    try appendIndented(allocator, &out, 3, "description: Generic JSON object (refine per-route when DTO known)\n");
    try appendIndented(allocator, &out, 2, "JsonOk:\n");
    try appendIndented(allocator, &out, 3, "type: object\n");
    try appendIndented(allocator, &out, 3, "properties:\n");
    try appendIndented(allocator, &out, 4, "ok:\n");
    try appendIndented(allocator, &out, 5, "type: boolean\n");
    try appendIndented(allocator, &out, 4, "data:\n");
    try appendIndented(allocator, &out, 5, "$ref: '#/components/schemas/JsonObject'\n");
    for (spec.dtos.items) |dto| {
        try appendDtoSchema(allocator, &out, dto, "");
        try appendDtoSchema(allocator, &out, dto, "Input");
    }
    try out.appendSlice(allocator, "paths:\n");

    // Group routes by path. spec.routes is already sorted, so first-occurrence
    // is the natural ordering.
    var i: usize = 0;
    while (i < spec.routes.items.len) {
        const path = spec.routes.items[i].path;
        try appendIndented(allocator, &out, 1, "");
        try out.appendSlice(allocator, path);
        try out.appendSlice(allocator, ":\n");

        // Emit all operations sharing this path consecutively.
        while (i < spec.routes.items.len and
            std.mem.eql(u8, spec.routes.items[i].path, path))
        {
            const r = spec.routes.items[i];
            try appendIndented(allocator, &out, 2, "");
            try out.appendSlice(allocator, methodLower(r.method));
            try out.appendSlice(allocator, ":\n");

            // parameters: from each {var} in the path (single source of truth).
            const params = try extractPathParamNames(allocator, path);
            defer freePathParamNames(allocator, params);

            if (params.len == 0) {
                try appendIndented(allocator, &out, 3, "parameters: []\n");
            } else {
                try appendIndented(allocator, &out, 3, "parameters:\n");
                for (params) |pname| {
                    try appendIndented(allocator, &out, 4, "- name: ");
                    try out.appendSlice(allocator, pname);
                    try out.append(allocator, '\n');
                    try appendIndented(allocator, &out, 5, "in: path\n");
                    try appendIndented(allocator, &out, 5, "required: true\n");
                    try appendIndented(allocator, &out, 5, "schema:\n");
                    try appendIndented(allocator, &out, 6, "type: string\n");
                }
            }

            const dto_guess_name = try dtoNameForPath(allocator, path);
            defer if (dto_guess_name) |n| allocator.free(n);
            const dto = if (dto_guess_name) |n| findDto(spec, n) else null;

            if (r.method == .POST or r.method == .PUT or r.method == .PATCH) {
                try appendIndented(allocator, &out, 3, "requestBody:\n");
                try appendIndented(allocator, &out, 4, "required: true\n");
                try appendIndented(allocator, &out, 4, "content:\n");
                try appendIndented(allocator, &out, 5, "application/json:\n");
                try appendIndented(allocator, &out, 6, "schema:\n");
                try appendIndented(allocator, &out, 7, "$ref: '#/components/schemas/");
                if (dto) |d| {
                    try out.appendSlice(allocator, d.name);
                    try out.appendSlice(allocator, "Input'\n");
                } else {
                    try out.appendSlice(allocator, "JsonObject'\n");
                }
                try appendIndented(allocator, &out, 3, "security:\n");
                try appendIndented(allocator, &out, 4, "- bearerAuth: []\n");
            }

            try appendIndented(allocator, &out, 3, "responses:\n");
            try appendIndented(allocator, &out, 4, "'200':\n");
            try appendIndented(allocator, &out, 5, "description: OK\n");
            try appendIndented(allocator, &out, 5, "content:\n");
            try appendIndented(allocator, &out, 6, "application/json:\n");
            try appendIndented(allocator, &out, 7, "schema:\n");
            try appendIndented(allocator, &out, 8, "$ref: '#/components/schemas/");
            if (dto) |d| {
                try out.appendSlice(allocator, d.name);
                try out.appendSlice(allocator, "'\n");
            } else {
                try out.appendSlice(allocator, "JsonOk'\n");
            }
            try appendIndented(allocator, &out, 4, "'400':\n");
            try appendIndented(allocator, &out, 5, "description: Bad Request\n");
            try appendIndented(allocator, &out, 5, "content:\n");
            try appendIndented(allocator, &out, 6, "application/json:\n");
            try appendIndented(allocator, &out, 7, "schema:\n");
            try appendIndented(allocator, &out, 8, "$ref: '#/components/schemas/HttpError'\n");
            if (r.method != .GET) {
                try appendIndented(allocator, &out, 4, "'401':\n");
                try appendIndented(allocator, &out, 5, "description: Unauthorized\n");
                try appendIndented(allocator, &out, 5, "content:\n");
                try appendIndented(allocator, &out, 6, "application/json:\n");
                try appendIndented(allocator, &out, 7, "schema:\n");
                try appendIndented(allocator, &out, 8, "$ref: '#/components/schemas/HttpError'\n");
            }
            if (params.len > 0) {
                try appendIndented(allocator, &out, 4, "'404':\n");
                try appendIndented(allocator, &out, 5, "description: Not Found\n");
                try appendIndented(allocator, &out, 5, "content:\n");
                try appendIndented(allocator, &out, 6, "application/json:\n");
                try appendIndented(allocator, &out, 7, "schema:\n");
                try appendIndented(allocator, &out, 8, "$ref: '#/components/schemas/HttpError'\n");
            }
            try appendIndented(allocator, &out, 4, "'422':\n");
            try appendIndented(allocator, &out, 5, "description: Unprocessable Entity\n");
            try appendIndented(allocator, &out, 5, "content:\n");
            try appendIndented(allocator, &out, 6, "application/json:\n");
            try appendIndented(allocator, &out, 7, "schema:\n");
            try appendIndented(allocator, &out, 8, "$ref: '#/components/schemas/HttpError'\n");
            try appendIndented(allocator, &out, 4, "'429':\n");
            try appendIndented(allocator, &out, 5, "description: Too Many Requests\n");
            try appendIndented(allocator, &out, 5, "content:\n");
            try appendIndented(allocator, &out, 6, "application/json:\n");
            try appendIndented(allocator, &out, 7, "schema:\n");
            try appendIndented(allocator, &out, 8, "$ref: '#/components/schemas/HttpError'\n");
            i += 1;
        }
    }

    return out.toOwnedSlice(allocator);
}

fn methodLower(m: HttpMethod) []const u8 {
    return switch (m) {
        .GET => "get",
        .POST => "post",
        .PUT => "put",
        .PATCH => "patch",
        .DELETE => "delete",
    };
}

/// Return the `{var}` names in `path`, in order of appearance. Caller owns
/// the outer slice AND each inner name; both must be freed via
/// `freePathParamNames`. The returned slice is always heap-allocated — even
/// when empty — so callers can `defer freePathParamNames(...)` unconditionally.
fn extractPathParamNames(allocator: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    var names = std.ArrayList([]const u8).empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var i: usize = 0;
    while (i < path.len) {
        if (path[i] == '{') {
            const end = std.mem.indexOfScalar(u8, path[i + 1 ..], '}') orelse break;
            try names.append(allocator, try allocator.dupe(u8, path[i + 1 .. i + 1 + end]));
            i += 1 + end + 1;
        } else {
            i += 1;
        }
    }
    return names.toOwnedSlice(allocator);
}

fn freePathParamNames(allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}

fn appendIndented(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: usize,
    text: []const u8,
) !void {
    var k: usize = 0;
    while (k < indent) : (k += 1) try out.append(allocator, ' ');
    try out.appendSlice(allocator, text);
}
