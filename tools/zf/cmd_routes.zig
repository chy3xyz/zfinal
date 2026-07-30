//! `zf routes` — scan `modules/**/actions.zig` → generate `routes.zig` + JSON manifest.
//! See doc/smart_routing.md.
const std = @import("std");
const zf_shared = @import("zf_shared.zig");

const readFileAlloc = zf_shared.readFileAlloc;

pub const NestedUnder = struct {
    parent: []const u8,
    param: []const u8,
};

pub const ModuleDecl = struct {
    name: []const u8,
    prefix: []const u8,
    api_prefix: []const u8 = "",
    param_id: []const u8 = "", // default "id" when empty
    nested_under: ?NestedUnder = null,
    interceptors: [][]const u8 = &.{},
    path: []const u8,
    dir: []const u8,
};

pub const ActionDecl = struct {
    name: []const u8,
    method: []const u8,
    path: []const u8,
    handler: []const u8,
    source: []const u8,
    interceptors: [][]const u8 = &.{},
};

pub const ParsedModule = struct {
    module: ModuleDecl,
    actions: []ActionDecl,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ParsedModule) void {
        self.allocator.free(self.module.name);
        self.allocator.free(self.module.prefix);
        self.allocator.free(self.module.api_prefix);
        self.allocator.free(self.module.param_id);
        self.allocator.free(self.module.path);
        self.allocator.free(self.module.dir);
        freeStringSlice(self.allocator, self.module.interceptors);
        if (self.module.nested_under) |n| {
            self.allocator.free(n.parent);
            self.allocator.free(n.param);
        }
        for (self.actions) |a| {
            self.allocator.free(a.name);
            self.allocator.free(a.method);
            self.allocator.free(a.path);
            self.allocator.free(a.handler);
            self.allocator.free(a.source);
            freeStringSlice(self.allocator, a.interceptors);
        }
        self.allocator.free(self.actions);
    }
};

fn freeStringSlice(allocator: std.mem.Allocator, ss: [][]const u8) void {
    for (ss) |s| allocator.free(s);
    allocator.free(ss);
}

/// Flat route for OpenAPI / external consumers.
pub const FlatRoute = struct {
    method: []const u8,
    path: []const u8,
    module: []const u8,
    source: []const u8,

    pub fn deinit(self: FlatRoute, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.path);
        allocator.free(self.module);
        allocator.free(self.source);
    }
};

/// Parse all actions under root and return owned flat routes (caller frees each + slice).
pub fn collectFlatRoutes(allocator: std.mem.Allocator, root: []const u8) ![]FlatRoute {
    var modules = try collectActionsFiles(allocator, root);
    defer {
        for (modules.items) |p| allocator.free(p);
        modules.deinit(allocator);
    }
    if (modules.items.len == 0) return try allocator.alloc(FlatRoute, 0);

    var parsed_list = std.ArrayList(ParsedModule).empty;
    defer {
        for (parsed_list.items) |*pm| pm.deinit();
        parsed_list.deinit(allocator);
    }
    for (modules.items) |path| {
        const src = try readFileAlloc(allocator, path);
        defer allocator.free(src);
        try parsed_list.append(allocator, try parseActionsFile(allocator, path, src));
    }
    try validateModules(parsed_list.items);
    try resolveAbsolutePaths(allocator, parsed_list.items);
    try detectConflicts(parsed_list.items);

    var out = std.ArrayList(FlatRoute).empty;
    errdefer {
        for (out.items) |r| r.deinit(allocator);
        out.deinit(allocator);
    }
    for (parsed_list.items) |pm| {
        for (pm.actions) |a| {
            try out.append(allocator, .{
                .method = try allocator.dupe(u8, a.method),
                .path = try allocator.dupe(u8, a.path),
                .module = try allocator.dupe(u8, pm.module.name),
                .source = try allocator.dupe(u8, a.source),
            });
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Entry: `zf routes [--json] [--check] [--root src/modules]`
pub fn handleRoutes(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const json_mode = zf_shared.hasFlag(args, "--json");
    const check_only = zf_shared.hasFlag(args, "--check");
    const root = zf_shared.flagValue(args, "--root") orelse "src/modules";

    var modules = try collectActionsFiles(allocator, root);
    defer {
        for (modules.items) |p| allocator.free(p);
        modules.deinit(allocator);
    }

    if (modules.items.len == 0) {
        std.debug.print("zf routes: no actions.zig under {s}\n", .{root});
        if (json_mode) std.debug.print("{{\"routes\":[],\"modules\":0}}\n", .{});
        return;
    }

    var parsed_list = std.ArrayList(ParsedModule).empty;
    defer {
        for (parsed_list.items) |*pm| pm.deinit();
        parsed_list.deinit(allocator);
    }

    for (modules.items) |path| {
        const src = try readFileAlloc(allocator, path);
        defer allocator.free(src);
        try parsed_list.append(allocator, try parseActionsFile(allocator, path, src));
    }

    try validateModules(parsed_list.items);
    try resolveAbsolutePaths(allocator, parsed_list.items);
    try detectConflicts(parsed_list.items);

    var fail: u32 = 0;
    for (parsed_list.items) |*pm| {
        const code = try emitRoutesZig(allocator, pm);
        defer allocator.free(code);
        const out_path = try std.fmt.allocPrint(allocator, "{s}/routes.zig", .{pm.module.dir});
        defer allocator.free(out_path);

        if (check_only) {
            const existing = readFileAlloc(allocator, out_path) catch null;
            if (existing) |e| {
                defer allocator.free(e);
                if (!std.mem.eql(u8, e, code)) {
                    std.debug.print("OUT OF DATE: {s}\n", .{out_path});
                    fail += 1;
                } else {
                    std.debug.print("OK: {s}\n", .{out_path});
                }
            } else {
                std.debug.print("MISSING: {s}\n", .{out_path});
                fail += 1;
            }
        } else {
            try std.Io.Dir.cwd().writeFile(zf_shared.io, .{ .sub_path = out_path, .data = code });
            std.debug.print("wrote {s} ({d} actions)\n", .{ out_path, pm.actions.len });
        }
    }

    if (json_mode) try emitJsonManifest(allocator, parsed_list.items);

    if (check_only and fail > 0) {
        std.debug.print("zf routes --check: {d} file(s) need regeneration\n", .{fail});
        std.process.exit(1);
    }
}

fn collectActionsFiles(allocator: std.mem.Allocator, root: []const u8) !std.ArrayList([]const u8) {
    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }
    try walkForActions(allocator, root, &out);
    return out;
}

fn walkForActions(allocator: std.mem.Allocator, dir_path: []const u8, out: *std.ArrayList([]const u8)) !void {
    var dir = std.Io.Dir.cwd().openDir(zf_shared.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(zf_shared.io);

    var it = dir.iterate();
    while (try it.next(zf_shared.io)) |entry| {
        if (entry.kind == .directory) {
            if (std.mem.eql(u8, entry.name, ".git") or std.mem.eql(u8, entry.name, "zig-cache")) continue;
            const sub = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
            defer allocator.free(sub);
            try walkForActions(allocator, sub, out);
        } else if (entry.kind == .file and std.mem.eql(u8, entry.name, "actions.zig")) {
            try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}/actions.zig", .{dir_path}));
        }
    }
}

fn parseActionsFile(allocator: std.mem.Allocator, path: []const u8, src: []const u8) !ParsedModule {
    return parseActionsFileAst(allocator, path, src) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => parseActionsFileHeuristic(allocator, path, src),
    };
}

fn parseActionsFileAst(allocator: std.mem.Allocator, path: []const u8, src: []const u8) !ParsedModule {
    const dir = std.fs.path.dirname(path) orelse path;
    const zsrc = try allocator.allocSentinel(u8, src.len, 0);
    defer allocator.free(zsrc);
    @memcpy(zsrc[0..src.len], src);

    var tree = try std.zig.Ast.parse(allocator, zsrc, .{});
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.AstParseFailed;

    var module_init: ?std.zig.Ast.Node.Index = null;
    var actions_init: ?std.zig.Ast.Node.Index = null;
    for (tree.rootDecls()) |decl| {
        const vd = tree.fullVarDecl(decl) orelse continue;
        const name_tok = vd.ast.mut_token + 1;
        if (tree.tokenTag(name_tok) != .identifier) continue;
        const dname = tree.tokenSlice(name_tok);
        const init = vd.ast.init_node.unwrap() orelse continue;
        if (std.mem.eql(u8, dname, "module")) module_init = init;
        if (std.mem.eql(u8, dname, "actions")) actions_init = init;
    }
    const mod_node = module_init orelse return error.AstParseFailed;
    const act_node = actions_init orelse return error.AstParseFailed;

    var buf: [2]std.zig.Ast.Node.Index = undefined;
    const mod_si = tree.fullStructInit(&buf, mod_node) orelse return error.AstParseFailed;

    const name = try astStructString(allocator, tree, mod_si, "name") orelse
        try allocator.dupe(u8, std.fs.path.basename(dir));
    errdefer allocator.free(name);

    const prefix = blk: {
        if (try astStructString(allocator, tree, mod_si, "prefix")) |p| break :blk p;
        const k = try kebab(allocator, name);
        defer allocator.free(k);
        break :blk try std.fmt.allocPrint(allocator, "/{s}", .{k});
    };
    errdefer allocator.free(prefix);

    const api_prefix = try astStructString(allocator, tree, mod_si, "api_prefix") orelse try allocator.dupe(u8, "");
    errdefer allocator.free(api_prefix);

    const param_id = try astStructString(allocator, tree, mod_si, "param_id") orelse try allocator.dupe(u8, "id");
    errdefer allocator.free(param_id);

    const mod_ics = try astStructStringList(allocator, tree, mod_si, "interceptors");
    errdefer freeStringSlice(allocator, mod_ics);

    var nested: ?NestedUnder = null;
    if (astStructField(tree, mod_si, "nested_under")) |nest_node| {
        var nbuf: [2]std.zig.Ast.Node.Index = undefined;
        const nsi = tree.fullStructInit(&nbuf, nest_node) orelse return error.AstParseFailed;
        const parent = try astStructString(allocator, tree, nsi, "parent") orelse return error.AstParseFailed;
        errdefer allocator.free(parent);
        const param = try astStructString(allocator, tree, nsi, "param") orelse return error.AstParseFailed;
        nested = .{ .parent = parent, .param = param };
    }

    var actions_list = std.ArrayList(ActionDecl).empty;
    errdefer {
        for (actions_list.items) |a| {
            allocator.free(a.name);
            allocator.free(a.method);
            allocator.free(a.path);
            allocator.free(a.handler);
            allocator.free(a.source);
            freeStringSlice(allocator, a.interceptors);
        }
        actions_list.deinit(allocator);
    }

    var abuf: [2]std.zig.Ast.Node.Index = undefined;
    const actions_ai = tree.fullArrayInit(&abuf, act_node) orelse return error.AstParseFailed;
    for (actions_ai.ast.elements) |elem| {
        var ebuf: [2]std.zig.Ast.Node.Index = undefined;
        const esi = tree.fullStructInit(&ebuf, elem) orelse continue;

        const handler_node = astStructField(tree, esi, "handler") orelse continue;
        const handler = try allocator.dupe(u8, tree.getNodeSource(handler_node));
        errdefer allocator.free(handler);

        const aname = try astStructString(allocator, tree, esi, "name") orelse {
            allocator.free(handler);
            continue;
        };
        errdefer allocator.free(aname);

        const method = blk: {
            if (astStructField(tree, esi, "method")) |mnode| {
                if (tree.nodeTag(mnode) == .enum_literal) {
                    break :blk try allocator.dupe(u8, tree.tokenSlice(tree.nodeMainToken(mnode)));
                }
            }
            break :blk try defaultMethod(allocator, aname);
        };
        errdefer allocator.free(method);

        const action_key = try astStructString(allocator, tree, esi, "action_key");
        const rel_path = try astStructString(allocator, tree, esi, "path");
        const act_ics = try astStructStringList(allocator, tree, esi, "interceptors");
        errdefer freeStringSlice(allocator, act_ics);

        var source_buf: []const u8 = undefined;
        var path_tmp: []const u8 = undefined;
        if (action_key) |ak| {
            path_tmp = ak;
            source_buf = try allocator.dupe(u8, "action_key");
            if (rel_path) |rp| allocator.free(rp);
        } else if (rel_path) |rp| {
            path_tmp = try joinPrefix(allocator, prefix, rp);
            allocator.free(rp);
            source_buf = try allocator.dupe(u8, if (std.mem.indexOf(u8, path_tmp, "*") != null) "wildcard" else "convention");
        } else {
            path_tmp = try conventionalPath(allocator, prefix, aname, param_id);
            source_buf = try allocator.dupe(u8, "convention");
        }

        try actions_list.append(allocator, .{
            .name = aname,
            .method = method,
            .path = path_tmp,
            .handler = handler,
            .source = source_buf,
            .interceptors = act_ics,
        });
    }

    return ParsedModule{
        .module = .{
            .name = name,
            .prefix = prefix,
            .api_prefix = api_prefix,
            .param_id = param_id,
            .nested_under = nested,
            .interceptors = mod_ics,
            .path = try allocator.dupe(u8, path),
            .dir = try allocator.dupe(u8, dir),
        },
        .actions = try actions_list.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn astStructField(tree: std.zig.Ast, si: std.zig.Ast.full.StructInit, name: []const u8) ?std.zig.Ast.Node.Index {
    for (si.ast.fields) |f| {
        const fname = astFieldName(tree, f) orelse continue;
        if (std.mem.eql(u8, fname, name)) return f;
    }
    return null;
}

fn astFieldName(tree: std.zig.Ast, value_node: std.zig.Ast.Node.Index) ?[]const u8 {
    const first = tree.firstToken(value_node);
    if (first >= 2 and tree.tokenTag(first - 1) == .equal and tree.tokenTag(first - 2) == .identifier)
        return tree.tokenSlice(first - 2);
    return null;
}

fn astDupStringLiteral(allocator: std.mem.Allocator, tree: std.zig.Ast, node: std.zig.Ast.Node.Index) !?[]u8 {
    if (tree.nodeTag(node) != .string_literal) return null;
    const raw = tree.tokenSlice(tree.nodeMainToken(node));
    return try std.zig.string_literal.parseAlloc(allocator, raw);
}

fn astStructString(allocator: std.mem.Allocator, tree: std.zig.Ast, si: std.zig.Ast.full.StructInit, name: []const u8) !?[]u8 {
    const node = astStructField(tree, si, name) orelse return null;
    return try astDupStringLiteral(allocator, tree, node);
}

fn astStructStringList(allocator: std.mem.Allocator, tree: std.zig.Ast, si: std.zig.Ast.full.StructInit, name: []const u8) ![][]const u8 {
    const node = astStructField(tree, si, name) orelse return try allocator.alloc([]const u8, 0);
    var buf: [2]std.zig.Ast.Node.Index = undefined;
    const ai = tree.fullArrayInit(&buf, node) orelse return try allocator.alloc([]const u8, 0);
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }
    for (ai.ast.elements) |e| {
        const s = try astDupStringLiteral(allocator, tree, e) orelse continue;
        try list.append(allocator, s);
    }
    return try list.toOwnedSlice(allocator);
}

/// Legacy brace/string scan — used when Ast.parse fails (recover/malformed).
fn parseActionsFileHeuristic(allocator: std.mem.Allocator, path: []const u8, src: []const u8) !ParsedModule {
    const dir = std.fs.path.dirname(path) orelse path;

    const name = try extractStringField(allocator, src, ".name") orelse
        try allocator.dupe(u8, std.fs.path.basename(dir));
    errdefer allocator.free(name);

    const prefix = blk: {
        if (try extractStringField(allocator, src, ".prefix")) |p| break :blk p;
        const k = try kebab(allocator, name);
        defer allocator.free(k);
        break :blk try std.fmt.allocPrint(allocator, "/{s}", .{k});
    };
    errdefer allocator.free(prefix);

    const api_prefix = try extractStringField(allocator, src, ".api_prefix") orelse try allocator.dupe(u8, "");
    errdefer allocator.free(api_prefix);

    const param_id = try extractStringField(allocator, src, ".param_id") orelse try allocator.dupe(u8, "id");
    errdefer allocator.free(param_id);

    // Module interceptors: only from `pub const module` block (before actions)
    const module_src = if (std.mem.indexOf(u8, src, "pub const actions")) |ap|
        src[0..ap]
    else
        src;
    const mod_ics = try extractStringList(allocator, module_src, ".interceptors") orelse try allocator.alloc([]const u8, 0);
    errdefer freeStringSlice(allocator, mod_ics);

    var nested: ?NestedUnder = null;
    if (std.mem.indexOf(u8, src, ".nested_under")) |npos| {
        const nest_src = src[npos..];
        const parent = try extractStringField(allocator, nest_src, ".parent") orelse return error.InvalidActions;
        errdefer allocator.free(parent);
        const param = try extractStringField(allocator, nest_src, ".param") orelse return error.InvalidActions;
        nested = .{ .parent = parent, .param = param };
    }

    var actions_list = std.ArrayList(ActionDecl).empty;
    errdefer {
        for (actions_list.items) |a| {
            allocator.free(a.name);
            allocator.free(a.method);
            allocator.free(a.path);
            allocator.free(a.handler);
            allocator.free(a.source);
            freeStringSlice(allocator, a.interceptors);
        }
        actions_list.deinit(allocator);
    }

    const actions_start = std.mem.indexOf(u8, src, "pub const actions") orelse 0;
    const actions_src = src[actions_start..];

    var idx: usize = 0;
    while (idx < actions_src.len) {
        const rel = std.mem.indexOf(u8, actions_src[idx..], ".name") orelse break;
        const at = idx + rel;
        // Walk back to the opening `.{` of this action so nested `.{"ic"}` braces are included.
        const block_start = blk: {
            var i: usize = at;
            while (i > 0) : (i -= 1) {
                if (actions_src[i] == '{' and i > 0 and actions_src[i - 1] == '.') break :blk i - 1;
                if (actions_src[i] == '{' and (i == 0 or actions_src[i - 1] != '.')) break :blk i;
            }
            break :blk at;
        };
        const block_end_rel = findBalancedClose(actions_src[block_start..]) orelse break;
        const block = actions_src[block_start .. block_start + block_end_rel];
        idx = block_start + block_end_rel + 1;

        const handler = try extractHandlerRef(allocator, block) orelse continue;
        errdefer allocator.free(handler);

        const aname = try extractStringAfter(allocator, block, 0);
        errdefer allocator.free(aname);

        const method = (try extractEnumMethod(allocator, block)) orelse try defaultMethod(allocator, aname);
        errdefer allocator.free(method);

        const action_key = try extractStringField(allocator, block, ".action_key");
        const rel_path = try extractStringField(allocator, block, ".path");
        const act_ics = try extractStringList(allocator, block, ".interceptors") orelse try allocator.alloc([]const u8, 0);
        errdefer freeStringSlice(allocator, act_ics);

        var source_buf: []const u8 = undefined;
        var path_tmp: []const u8 = undefined;
        if (action_key) |ak| {
            path_tmp = ak;
            source_buf = try allocator.dupe(u8, "action_key");
            if (rel_path) |rp| allocator.free(rp);
        } else if (rel_path) |rp| {
            path_tmp = try joinPrefix(allocator, prefix, rp);
            allocator.free(rp);
            source_buf = try allocator.dupe(u8, if (std.mem.indexOf(u8, path_tmp, "*") != null) "wildcard" else "convention");
        } else {
            path_tmp = try conventionalPath(allocator, prefix, aname, param_id);
            source_buf = try allocator.dupe(u8, "convention");
        }

        try actions_list.append(allocator, .{
            .name = aname,
            .method = method,
            .path = path_tmp,
            .handler = handler,
            .source = source_buf,
            .interceptors = act_ics,
        });
    }

    return ParsedModule{
        .module = .{
            .name = name,
            .prefix = prefix,
            .api_prefix = api_prefix,
            .param_id = param_id,
            .nested_under = nested,
            .interceptors = mod_ics,
            .path = try allocator.dupe(u8, path),
            .dir = try allocator.dupe(u8, dir),
        },
        .actions = try actions_list.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn resolveAbsolutePaths(allocator: std.mem.Allocator, modules: []ParsedModule) !void {
    for (modules) |*pm| {
        const abs = try computeModuleAbsPrefix(allocator, pm, modules);
        defer allocator.free(abs);
        const pid = if (pm.module.param_id.len > 0) pm.module.param_id else "id";

        if (pm.module.nested_under != null) {
            for (pm.actions) |*a| {
                if (std.mem.eql(u8, a.source, "action_key")) continue;
                const new_path = try conventionalPath(allocator, abs, a.name, pid);
                if (std.mem.eql(u8, a.source, "wildcard")) {
                    if (std.mem.lastIndexOfScalar(u8, a.path, '*')) |star| {
                        const star_seg = a.path[star..];
                        allocator.free(new_path);
                        const wp = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ abs, star_seg });
                        allocator.free(a.path);
                        a.path = wp;
                    } else {
                        allocator.free(a.path);
                        a.path = new_path;
                    }
                } else {
                    allocator.free(a.path);
                    a.path = new_path;
                    allocator.free(a.source);
                    a.source = try allocator.dupe(u8, "nested");
                }
            }
        } else if (pm.module.api_prefix.len > 0) {
            for (pm.actions) |*a| {
                if (std.mem.eql(u8, a.source, "action_key")) continue;
                if (std.mem.startsWith(u8, a.path, pm.module.api_prefix)) continue;
                const new_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ pm.module.api_prefix, a.path });
                allocator.free(a.path);
                a.path = new_path;
            }
        }
    }
}

fn validateModules(modules: []ParsedModule) !void {
    for (modules) |pm| {
        if (pm.module.nested_under) |n| {
            if (std.mem.eql(u8, n.param, "id")) {
                std.debug.print("ERROR: module {s} nested_under.param must not be \"id\" (use user_id etc.)\n", .{pm.module.name});
                return error.NestedDuplicateIdParam;
            }
            var found_parent = false;
            for (modules) |other| {
                if (std.mem.eql(u8, other.module.name, n.parent)) {
                    found_parent = true;
                    if (other.module.nested_under != null) {
                        std.debug.print("ERROR: nested depth > 2 ({s} under nested {s})\n", .{ pm.module.name, other.module.name });
                        return error.NestedTooDeep;
                    }
                    break;
                }
            }
            if (!found_parent) {
                std.debug.print("ERROR: nested parent \"{s}\" not found for module {s}\n", .{ n.parent, pm.module.name });
                return error.NestedParentMissing;
            }
        }
        for (pm.actions) |a| {
            try validateWildcardPath(a.path, pm.module.name, a.name);
        }
    }
}

fn validateWildcardPath(path: []const u8, module: []const u8, action: []const u8) !void {
    var stars: usize = 0;
    var parts = std.mem.splitScalar(u8, path, '/');
    var last_was_star = false;
    var seg_count: usize = 0;
    while (parts.next()) |p| {
        if (p.len == 0) continue;
        seg_count += 1;
        last_was_star = false;
        if (p[0] == '*') {
            stars += 1;
            last_was_star = true;
            if (std.mem.indexOfScalar(u8, p[1..], '*') != null) {
                std.debug.print("ERROR: {s}.{s} invalid wildcard segment {s}\n", .{ module, action, p });
                return error.InvalidWildcard;
            }
        }
    }
    if (stars > 1) {
        std.debug.print("ERROR: {s}.{s} has multiple * in path {s}\n", .{ module, action, path });
        return error.InvalidWildcard;
    }
    if (stars == 1 and !last_was_star) {
        std.debug.print("ERROR: {s}.{s} * must be last segment in {s}\n", .{ module, action, path });
        return error.InvalidWildcard;
    }
}

fn computeModuleAbsPrefix(allocator: std.mem.Allocator, pm: *ParsedModule, all: []ParsedModule) ![]const u8 {
    const own = if (pm.module.api_prefix.len > 0)
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ pm.module.api_prefix, pm.module.prefix })
    else
        try allocator.dupe(u8, pm.module.prefix);

    const nested = pm.module.nested_under orelse return own;
    defer allocator.free(own);

    for (all) |other| {
        if (!std.mem.eql(u8, other.module.name, nested.parent)) continue;
        if (other.module.nested_under != null) return error.NestedTooDeep;
        const parent_abs = if (other.module.api_prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ other.module.api_prefix, other.module.prefix })
        else
            try allocator.dupe(u8, other.module.prefix);
        defer allocator.free(parent_abs);
        return try std.fmt.allocPrint(allocator, "{s}/:{s}{s}", .{ parent_abs, nested.param, pm.module.prefix });
    }
    return error.NestedParentMissing;
}

fn detectConflicts(modules: []ParsedModule) !void {
    if (modules.len == 0) return;
    const allocator = modules[0].allocator;
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit();
    }
    for (modules) |pm| {
        for (pm.actions) |a| {
            const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ a.method, a.path });
            const gop = try seen.getOrPut(key);
            if (gop.found_existing) {
                std.debug.print("CONFLICT: {s} {s} (module {s} action {s})\n", .{ a.method, a.path, pm.module.name, a.name });
                allocator.free(key);
                return error.RouteConflict;
            }
        }
    }
}

fn moduleNeedsInterceptorImport(pm: *const ParsedModule) bool {
    if (pm.module.interceptors.len > 0) return true;
    for (pm.actions) |a| {
        if (a.interceptors.len > 0) return true;
    }
    return false;
}

fn relativeInterceptImport(allocator: std.mem.Allocator, module_dir: []const u8) ![]const u8 {
    // From src/modules/<...> or **/modules/<...> up to parent of modules/, then interceptors.zig
    const marker = "modules/";
    const idx = std.mem.lastIndexOf(u8, module_dir, marker) orelse return try allocator.dupe(u8, "../../interceptors.zig");
    const after = module_dir[idx + marker.len ..];
    var comps: usize = 0;
    if (after.len > 0) {
        comps = 1;
        for (after) |c| {
            if (c == '/') comps += 1;
        }
    }
    const ups = comps + 1; // to modules/ then to its parent (src/)
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    const w = &buf.writer;
    var i: usize = 0;
    while (i < ups) : (i += 1) try w.writeAll("../");
    try w.writeAll("interceptors.zig");
    return try buf.toOwnedSlice();
}

fn emitMergedInterceptorRefs(w: *std.Io.Writer, mod_ics: [][]const u8, act_ics: [][]const u8) !void {
    try w.writeAll("&.{ ");
    var first = true;
    for (mod_ics) |name| {
        if (!first) try w.writeAll(", ");
        first = false;
        try w.print("ic.{s}", .{name});
    }
    for (act_ics) |name| {
        // skip dup names already in module list
        var dup = false;
        for (mod_ics) |m| {
            if (std.mem.eql(u8, m, name)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        if (!first) try w.writeAll(", ");
        first = false;
        try w.print("ic.{s}", .{name});
    }
    try w.writeAll(" }");
}

fn emitRoutesZig(allocator: std.mem.Allocator, pm: *ParsedModule) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    const w = &buf.writer;

    try w.writeAll("// @generated by zf routes — DO NOT EDIT\n");
    try w.writeAll("// Regenerate: zf routes\n");
    try w.writeAll("const handler = @import(\"handler.zig\");\n");
    const need_ic = moduleNeedsInterceptorImport(pm);
    if (need_ic) {
        const rel = try relativeInterceptImport(allocator, pm.module.dir);
        defer allocator.free(rel);
        try w.print("const ic = @import(\"{s}\");\n", .{rel});
    }
    try w.writeAll("\npub fn register(app: anytype) !void {\n");
    for (pm.actions) |a| {
        const has_ics = pm.module.interceptors.len > 0 or a.interceptors.len > 0;
        const meth = methodToFn(a.method);
        if (has_ics) {
            try w.print("    try app.{s}WithInterceptors(\"{s}\", {s}, ", .{ meth, a.path, a.handler });
            try emitMergedInterceptorRefs(w, pm.module.interceptors, a.interceptors);
            try w.writeAll(");\n");
        } else {
            try w.print("    try app.{s}(\"{s}\", {s});\n", .{ meth, a.path, a.handler });
        }
    }
    try w.writeAll("}\n");
    return try buf.toOwnedSlice();
}

fn methodToFn(method: []const u8) []const u8 {
    if (std.mem.eql(u8, method, "GET")) return "get";
    if (std.mem.eql(u8, method, "POST")) return "post";
    if (std.mem.eql(u8, method, "PUT")) return "put";
    if (std.mem.eql(u8, method, "PATCH")) return "patch";
    if (std.mem.eql(u8, method, "DELETE")) return "delete";
    return "get";
}

fn pathParamsList(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |p| {
        if (p.len > 1 and p[0] == ':') {
            try list.append(allocator, try allocator.dupe(u8, p[1..]));
        } else if (p.len > 1 and p[0] == '*') {
            try list.append(allocator, try allocator.dupe(u8, p[1..]));
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn emitJsonManifest(allocator: std.mem.Allocator, modules: []ParsedModule) !void {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;
    try w.writeAll("{\"routes\":[");
    var first = true;
    for (modules) |pm| {
        for (pm.actions) |a| {
            if (!first) try w.writeAll(",");
            first = false;
            try w.print(
                \\{{"method":"{s}","path":"{s}","handler":"{s}","source":"{s}","module":"{s}"
            , .{ a.method, a.path, a.handler, a.source, pm.module.name });
            const params = try pathParamsList(allocator, a.path);
            defer freeStringSlice(allocator, params);
            try w.writeAll(",\"params\":[");
            for (params, 0..) |p, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("\"{s}\"", .{p});
            }
            try w.writeAll("]");
            // merged interceptors
            try w.writeAll(",\"interceptors\":[");
            var ifirst = true;
            for (pm.module.interceptors) |name| {
                if (!ifirst) try w.writeAll(",");
                ifirst = false;
                try w.print("\"{s}\"", .{name});
            }
            for (a.interceptors) |name| {
                var dup = false;
                for (pm.module.interceptors) |m| {
                    if (std.mem.eql(u8, m, name)) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
                if (!ifirst) try w.writeAll(",");
                ifirst = false;
                try w.print("\"{s}\"", .{name});
            }
            try w.writeAll("]");
            if (pm.module.nested_under) |n| {
                try w.print(",\"nested_under\":{{\"parent\":\"{s}\",\"param\":\"{s}\"}}", .{ n.parent, n.param });
            }
            try w.writeAll("}");
        }
    }
    try w.print("],\"modules\":{d}}}\n", .{modules.len});
    const out = try buf.toOwnedSlice();
    defer allocator.free(out);
    std.debug.print("{s}", .{out});
}

fn conventionalPath(allocator: std.mem.Allocator, prefix: []const u8, action_name: []const u8, param_id: []const u8) ![]const u8 {
    const pid = if (param_id.len > 0) param_id else "id";
    if (std.mem.eql(u8, action_name, "index") or std.mem.eql(u8, action_name, "list") or std.mem.eql(u8, action_name, "create")) {
        return try allocator.dupe(u8, prefix);
    }
    if (std.mem.eql(u8, action_name, "show") or std.mem.eql(u8, action_name, "update") or
        std.mem.eql(u8, action_name, "patch") or std.mem.eql(u8, action_name, "destroy") or
        std.mem.eql(u8, action_name, "delete"))
    {
        return try std.fmt.allocPrint(allocator, "{s}/:{s}", .{ prefix, pid });
    }
    const kebab_name = try kebab(allocator, action_name);
    defer allocator.free(kebab_name);
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, kebab_name });
}

fn defaultMethod(allocator: std.mem.Allocator, action_name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, action_name, "index") or std.mem.eql(u8, action_name, "list") or std.mem.eql(u8, action_name, "show"))
        return try allocator.dupe(u8, "GET");
    if (std.mem.eql(u8, action_name, "create")) return try allocator.dupe(u8, "POST");
    if (std.mem.eql(u8, action_name, "update")) return try allocator.dupe(u8, "PUT");
    if (std.mem.eql(u8, action_name, "patch")) return try allocator.dupe(u8, "PATCH");
    if (std.mem.eql(u8, action_name, "destroy") or std.mem.eql(u8, action_name, "delete"))
        return try allocator.dupe(u8, "DELETE");
    return try allocator.dupe(u8, "POST");
}

fn joinPrefix(allocator: std.mem.Allocator, prefix: []const u8, rel: []const u8) ![]const u8 {
    if (rel.len == 0) return try allocator.dupe(u8, prefix);
    if (rel.len > 0 and rel[0] == '/') {
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, rel });
    }
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, rel });
}

fn kebab(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    const w = &buf.writer;
    for (name, 0..) |c, i| {
        if (c >= 'A' and c <= 'Z') {
            if (i > 0) try w.writeByte('-');
            try w.writeByte(c + 32);
        } else if (c == '_' or c == ' ') {
            try w.writeByte('-');
        } else {
            try w.writeByte(c);
        }
    }
    return try buf.toOwnedSlice();
}

/// Index of the `}` that closes the first `{` or `.{` in `src`, or null.
fn findBalancedClose(src: []const u8) ?usize {
    var depth: i32 = 0;
    var in_str = false;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (in_str) {
            if (c == '\\' and i + 1 < src.len) {
                i += 1;
                continue;
            }
            if (c == '"') in_str = false;
            continue;
        }
        if (c == '"') {
            in_str = true;
            continue;
        }
        if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn extractStringField(allocator: std.mem.Allocator, src: []const u8, field: []const u8) !?[]const u8 {
    const pos = std.mem.indexOf(u8, src, field) orelse return null;
    return try extractStringAfter(allocator, src, pos);
}

/// Parse `.interceptors = .{ "a", "b" }` → owned slice of names.
fn extractStringList(allocator: std.mem.Allocator, src: []const u8, field: []const u8) !?[][]const u8 {
    const pos = std.mem.indexOf(u8, src, field) orelse return null;
    const slice = src[pos..];
    const brace = std.mem.indexOf(u8, slice, ".{") orelse return null;
    const rest = slice[brace + 2 ..];
    const end = std.mem.indexOfScalar(u8, rest, '}') orelse return null;
    const inner = rest[0..end];
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }
    var search: usize = 0;
    while (search < inner.len) {
        const q1 = std.mem.indexOfScalar(u8, inner[search..], '"') orelse break;
        const from = search + q1 + 1;
        const q2 = std.mem.indexOfScalar(u8, inner[from..], '"') orelse break;
        try list.append(allocator, try allocator.dupe(u8, inner[from .. from + q2]));
        search = from + q2 + 1;
    }
    return try list.toOwnedSlice(allocator);
}

fn extractStringAfter(allocator: std.mem.Allocator, src: []const u8, from: usize) ![]const u8 {
    const slice = src[from..];
    const q1 = std.mem.indexOfScalar(u8, slice, '"') orelse return error.InvalidActions;
    const rest = slice[q1 + 1 ..];
    const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse return error.InvalidActions;
    return try allocator.dupe(u8, rest[0..q2]);
}

fn extractHandlerRef(allocator: std.mem.Allocator, block: []const u8) !?[]const u8 {
    const key = ".handler";
    const pos = std.mem.indexOf(u8, block, key) orelse return null;
    var i = pos + key.len;
    while (i < block.len and (block[i] == ' ' or block[i] == '=')) : (i += 1) {}
    const start = i;
    while (i < block.len) : (i += 1) {
        const c = block[i];
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '.'))
            break;
    }
    if (i == start) return null;
    return try allocator.dupe(u8, block[start..i]);
}

fn extractEnumMethod(allocator: std.mem.Allocator, block: []const u8) !?[]const u8 {
    const key = ".method";
    const pos = std.mem.indexOf(u8, block, key) orelse return null;
    const slice = block[pos..];
    const end = @min(slice.len, 32);
    const window = slice[0..end];
    if (std.mem.indexOf(u8, window, ".GET")) |_| return try allocator.dupe(u8, "GET");
    if (std.mem.indexOf(u8, window, ".POST")) |_| return try allocator.dupe(u8, "POST");
    if (std.mem.indexOf(u8, window, ".PUT")) |_| return try allocator.dupe(u8, "PUT");
    if (std.mem.indexOf(u8, window, ".PATCH")) |_| return try allocator.dupe(u8, "PATCH");
    if (std.mem.indexOf(u8, window, ".DELETE")) |_| return try allocator.dupe(u8, "DELETE");
    return null;
}

test "kebab UserProfile" {
    const allocator = std.testing.allocator;
    const k = try kebab(allocator, "UserProfile");
    defer allocator.free(k);
    try std.testing.expectEqualStrings("user-profile", k);
}

test "conventionalPath index and show" {
    const allocator = std.testing.allocator;
    const a = try conventionalPath(allocator, "/users", "index", "id");
    defer allocator.free(a);
    try std.testing.expectEqualStrings("/users", a);
    const b = try conventionalPath(allocator, "/users", "show", "id");
    defer allocator.free(b);
    try std.testing.expectEqualStrings("/users/:id", b);
}

test "parseActionsFileAst preferred over heuristic for nested interceptors" {
    const allocator = std.testing.allocator;
    // Valid Zig syntax; AST must see action-level interceptors inside nested braces.
    var pm = try parseActionsFileAst(allocator, "src/modules/api/actions.zig",
        \\pub const module = .{ .name = "api", .prefix = "/api" };
        \\pub const actions = .{
        \\    .{ .name = "submit", .method = .POST, .action_key = "/api/submit", .handler = handler.submit,
        \\       .interceptors = .{"csrf", "audit"} },
        \\};
    );
    defer pm.deinit();
    try std.testing.expectEqual(@as(usize, 2), pm.actions[0].interceptors.len);
    try std.testing.expectEqualStrings("csrf", pm.actions[0].interceptors[0]);
    try std.testing.expectEqualStrings("audit", pm.actions[0].interceptors[1]);
}

test "parseActionsFile falls back when source is not valid Zig" {
    const allocator = std.testing.allocator;
    // Broken Zig (missing braces) — Ast fails; heuristic may still recover fields.
    var pm = try parseActionsFile(allocator, "src/modules/users/actions.zig",
        \\pub const module = .{ .name = "users", .prefix = "/users"
        \\pub const actions = .{
        \\    .{ .name = "index", .handler = handler.index },
        \\};
    );
    defer pm.deinit();
    try std.testing.expectEqualStrings("users", pm.module.name);
    try std.testing.expect(pm.actions.len >= 1);
}

test "parseActionsFile action-only interceptors" {
    const allocator = std.testing.allocator;
    var pm = try parseActionsFile(allocator, "src/modules/api/actions.zig",
        \\pub const module = .{ .name = "api", .prefix = "/api" };
        \\pub const actions = .{
        \\    .{ .name = "submit", .method = .POST, .action_key = "/api/submit", .handler = handler.submit,
        \\       .interceptors = .{"csrf"} },
        \\};
    );
    defer pm.deinit();
    try std.testing.expectEqual(@as(usize, 1), pm.actions[0].interceptors.len);
    try std.testing.expectEqualStrings("csrf", pm.actions[0].interceptors[0]);
    const code = try emitRoutesZig(allocator, &pm);
    defer allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "postWithInterceptors") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "ic.csrf") != null);
}

test "parseActionsFile interceptors emit WithInterceptors" {
    const allocator = std.testing.allocator;
    var pm = try parseActionsFile(allocator, "src/modules/users/actions.zig",
        \\pub const module = .{
        \\    .name = "users",
        \\    .prefix = "/users",
        \\    .interceptors = .{ "auth", "access_log" },
        \\};
        \\pub const actions = .{
        \\    .{ .name = "index", .handler = handler.index },
        \\    .{ .name = "login", .method = .POST, .action_key = "/auth/login", .handler = handler.login,
        \\       .interceptors = .{"rate_limit"} },
        \\};
    );
    defer pm.deinit();
    try std.testing.expectEqual(@as(usize, 2), pm.module.interceptors.len);
    const code = try emitRoutesZig(allocator, &pm);
    defer allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "getWithInterceptors") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "ic.auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "ic.rate_limit") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "interceptors.zig") != null);
}

test "validateModules rejects nested param id" {
    const allocator = std.testing.allocator;
    var mods = [_]ParsedModule{
        try parseActionsFile(allocator, "src/modules/users/actions.zig",
            \\pub const module = .{ .name = "users", .prefix = "/users" };
            \\pub const actions = .{ .{ .name = "index", .handler = handler.index }, };
        ),
        try parseActionsFile(allocator, "src/modules/orders/actions.zig",
            \\pub const module = .{
            \\    .name = "orders",
            \\    .prefix = "/orders",
            \\    .nested_under = .{ .parent = "users", .param = "id" },
            \\};
            \\pub const actions = .{ .{ .name = "index", .handler = handler.index }, };
        ),
    };
    defer for (&mods) |*m| m.deinit();
    try std.testing.expectError(error.NestedDuplicateIdParam, validateModules(&mods));
}

test "parseActionsFile nested resolve" {
    const allocator = std.testing.allocator;
    var mods = [_]ParsedModule{
        try parseActionsFile(allocator, "src/modules/users/actions.zig",
            \\pub const module = .{ .name = "users", .prefix = "/users" };
            \\pub const actions = .{
            \\    .{ .name = "index", .handler = handler.index },
            \\    .{ .name = "show", .handler = handler.show },
            \\};
        ),
        try parseActionsFile(allocator, "src/modules/orders/actions.zig",
            \\pub const module = .{
            \\    .name = "orders",
            \\    .prefix = "/orders",
            \\    .nested_under = .{ .parent = "users", .param = "user_id" },
            \\};
            \\pub const actions = .{
            \\    .{ .name = "index", .handler = handler.index },
            \\    .{ .name = "show", .handler = handler.show },
            \\};
        ),
    };
    defer for (&mods) |*m| m.deinit();

    try resolveAbsolutePaths(allocator, &mods);
    try std.testing.expectEqualStrings("/users/:user_id/orders", mods[1].actions[0].path);
    try std.testing.expectEqualStrings("/users/:user_id/orders/:id", mods[1].actions[1].path);
    try std.testing.expectEqualStrings("nested", mods[1].actions[0].source);
}
