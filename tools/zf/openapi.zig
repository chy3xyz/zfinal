//! Minimal OpenAPI 3.0.3 spec generator for ZFinal projects.
//!
//! Scans Zig source files for static route registrations and renders an
//! OpenAPI YAML document covering:
//!   - `app.get/post/put/patch/delete("/path", ...)`
//!   - `app.getWithInterceptors/...` variants
//!   - `RouteGroup.init(&app, "/prefix")` + group `.get/post/...`
//!
//! v0.21 infers path strings + path parameters, adds bearer JWT security on
//! mutating operations, generic JSON request bodies, and standard error
//! responses (400/401/404). Response schemas are still not introspected.

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

/// Parsed OpenAPI spec. `routes` is sorted by (path, method) and deduped.
pub const Spec = struct {
    title: []const u8,
    version: []const u8,
    routes: std.ArrayList(Route),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Spec) void {
        for (self.routes.items) |r| self.allocator.free(r.path);
        self.routes.deinit(self.allocator);
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
// YAML renderer
// ─────────────────────────────────────────────────────────────────────────────

/// Render `spec` as an OpenAPI 3.0.3 YAML document.
///
/// Each operation has path parameters, standard responses, and (for POST/PUT/PATCH)
/// a generic JSON request body. Mutating operations declare `bearerAuth` security.
/// The renderer is deterministic: same spec → same bytes.
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

            if (r.method == .POST or r.method == .PUT or r.method == .PATCH) {
                try appendIndented(allocator, &out, 3, "requestBody:\n");
                try appendIndented(allocator, &out, 4, "required: true\n");
                try appendIndented(allocator, &out, 4, "content:\n");
                try appendIndented(allocator, &out, 5, "application/json:\n");
                try appendIndented(allocator, &out, 6, "schema:\n");
                try appendIndented(allocator, &out, 7, "$ref: '#/components/schemas/JsonObject'\n");
                try appendIndented(allocator, &out, 3, "security:\n");
                try appendIndented(allocator, &out, 4, "- bearerAuth: []\n");
            }

            try appendIndented(allocator, &out, 3, "responses:\n");
            try appendIndented(allocator, &out, 4, "'200':\n");
            try appendIndented(allocator, &out, 5, "description: OK\n");
            try appendIndented(allocator, &out, 5, "content:\n");
            try appendIndented(allocator, &out, 6, "application/json:\n");
            try appendIndented(allocator, &out, 7, "schema:\n");
            try appendIndented(allocator, &out, 8, "$ref: '#/components/schemas/JsonOk'\n");
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
