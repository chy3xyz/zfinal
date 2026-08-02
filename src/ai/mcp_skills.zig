//! Bridge MCP tools into SkillRegistry for Agent ReAct.
//! Own an `McpBridge` per client; set `skill_ctx.backend_ptr = &bridge`.

const std = @import("std");
const skill_mod = @import("skill.zig");
const mcp_client = @import("mcp_client.zig");
const time_util = @import("time_util.zig");

pub const SkillRegistry = skill_mod.SkillRegistry;
pub const SkillContext = skill_mod.SkillContext;
pub const Param = skill_mod.Param;
pub const Tool = skill_mod.Tool;
pub const freeValue = skill_mod.freeValue;
pub const McpClient = mcp_client.McpClient;

pub const McpImportOpts = struct {
    /// Prefixed onto MCP tool names (OpenAI-safe).
    name_prefix: []const u8 = "mcp.",
    /// Filter by original MCP tool name; null = import all.
    allowlist: ?[]const []const u8 = null,
    timeout_ms: ?u64 = 15_000,
};

/// Owned metadata kept alive for registered tools (description + remote name + params).
const BridgeMeta = struct {
    remote_name: []const u8,
    description: []const u8,
    params: []Param,
};

/// Per-client MCP→Skill bridge (no process globals).
pub const McpBridge = struct {
    allocator: std.mem.Allocator,
    client: *McpClient,
    remote_by_reg: std.StringHashMap([]const u8),
    metas: std.ArrayList(*BridgeMeta),

    pub fn init(allocator: std.mem.Allocator, client: *McpClient) McpBridge {
        return .{
            .allocator = allocator,
            .client = client,
            .remote_by_reg = std.StringHashMap([]const u8).init(allocator),
            .metas = .empty,
        };
    }

    pub fn deinit(self: *McpBridge) void {
        for (self.metas.items) |m| {
            self.allocator.free(m.remote_name);
            self.allocator.free(m.description);
            for (m.params) |p| {
                self.allocator.free(p.name);
                self.allocator.free(p.description);
            }
            self.allocator.free(m.params);
            self.allocator.destroy(m);
        }
        self.metas.deinit(self.allocator);
        var it = self.remote_by_reg.iterator();
        while (it.next()) |e| self.allocator.free(e.key_ptr.*);
        self.remote_by_reg.deinit();
        self.* = undefined;
    }

    /// Import MCP tools into `registry`. Returns number registered.
    /// Keep this bridge alive for Agent runs; set `skill_ctx.backend_ptr = bridge`.
    pub fn registerInto(self: *McpBridge, registry: *SkillRegistry, opts: McpImportOpts) !usize {
        const allocator = self.allocator;
        const deadline: ?i64 = if (opts.timeout_ms) |ms|
            time_util.nowMillis() + @as(i64, @intCast(ms))
        else
            null;

        const tools = try self.client.listToolsOpts(.{ .deadline_ms = deadline });
        defer self.client.freeTools(tools);

        var count: usize = 0;
        for (tools) |t| {
            if (!allowed(t.name, opts.allowlist)) continue;

            const reg_name = try sanitizeToolName(allocator, opts.name_prefix, t.name);
            errdefer allocator.free(reg_name);

            const meta = try allocator.create(BridgeMeta);
            errdefer allocator.destroy(meta);
            meta.* = .{
                .remote_name = try allocator.dupe(u8, t.name),
                .description = try allocator.dupe(u8, t.description),
                .params = try paramsFromSchema(allocator, t.input_schema_json),
            };
            errdefer {
                allocator.free(meta.remote_name);
                allocator.free(meta.description);
                for (meta.params) |p| {
                    allocator.free(p.name);
                    allocator.free(p.description);
                }
                allocator.free(meta.params);
            }
            try self.metas.append(allocator, meta);
            errdefer {
                _ = self.metas.pop();
            }

            const key_dup = try allocator.dupe(u8, reg_name);
            self.remote_by_reg.put(key_dup, meta.remote_name) catch |err| {
                allocator.free(key_dup);
                return err;
            };
            errdefer {
                _ = self.remote_by_reg.remove(key_dup);
                allocator.free(key_dup);
            }

            try registry.register(.{
                .name = reg_name,
                .description = meta.description,
                .parameters = meta.params,
                .timeout_ms = opts.timeout_ms,
                .handler = mcpHandler,
            });
            allocator.free(reg_name); // registry duped the name
            count += 1;
        }
        return count;
    }
};

/// Convenience: register via bridge (preferred entry for AiRuntime).
pub fn registerMcpTools(registry: *SkillRegistry, bridge: *McpBridge, opts: McpImportOpts) !usize {
    return bridge.registerInto(registry, opts);
}

/// Deprecated no-op — use `McpBridge.deinit`. Kept so older call sites compile.
pub fn deinitBridgeMetas(_: std.mem.Allocator) void {}

fn bridgeFrom(ctx: *SkillContext) !*McpBridge {
    if (ctx.backend_ptr) |p| return @ptrCast(@alignCast(p));
    if (ctx.userdata) |p| return @ptrCast(@alignCast(p));
    return error.McpNotConfigured;
}

fn allowed(name: []const u8, allowlist: ?[]const []const u8) bool {
    const list = allowlist orelse return true;
    for (list) |a| {
        if (std.mem.eql(u8, a, name)) return true;
    }
    return false;
}

fn sanitizeToolName(allocator: std.mem.Allocator, prefix: []const u8, raw: []const u8) ![]u8 {
    var buf = try allocator.alloc(u8, prefix.len + raw.len);
    @memcpy(buf[0..prefix.len], prefix);
    for (raw, 0..) |c, i| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-' or c == '.';
        buf[prefix.len + i] = if (ok) c else '_';
    }
    return buf;
}

fn mapJsonType(t: []const u8) Param.Type {
    if (std.mem.eql(u8, t, "number") or std.mem.eql(u8, t, "integer")) return .number;
    if (std.mem.eql(u8, t, "boolean")) return .boolean;
    if (std.mem.eql(u8, t, "array")) return .array;
    if (std.mem.eql(u8, t, "object")) return .object;
    return .string;
}

fn paramsFromSchema(allocator: std.mem.Allocator, schema_json: []const u8) ![]Param {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, schema_json, .{}) catch {
        return try allocator.alloc(Param, 0);
    };
    defer parsed.deinit();
    if (parsed.value != .object) return try allocator.alloc(Param, 0);

    const props = parsed.value.object.get("properties") orelse return try allocator.alloc(Param, 0);
    if (props != .object) return try allocator.alloc(Param, 0);

    var required_set = std.StringHashMap(void).init(allocator);
    defer required_set.deinit();
    if (parsed.value.object.get("required")) |req| {
        if (req == .array) {
            for (req.array.items) |item| {
                if (item == .string) try required_set.put(item.string, {});
            }
        }
    }

    var list = std.ArrayList(Param).empty;
    errdefer {
        for (list.items) |p| {
            allocator.free(p.name);
            allocator.free(p.description);
        }
        list.deinit(allocator);
    }

    var it = props.object.iterator();
    while (it.next()) |e| {
        const pname = e.key_ptr.*;
        var ptype: Param.Type = .string;
        var pdesc: []const u8 = "";
        if (e.value_ptr.* == .object) {
            if (e.value_ptr.object.get("type")) |tv| {
                if (tv == .string) ptype = mapJsonType(tv.string);
            }
            if (e.value_ptr.object.get("description")) |dv| {
                if (dv == .string) pdesc = dv.string;
            }
        }
        try list.append(allocator, .{
            .name = try allocator.dupe(u8, pname),
            .type = ptype,
            .description = try allocator.dupe(u8, pdesc),
            .required = required_set.contains(pname),
        });
    }
    return try list.toOwnedSlice(allocator);
}

fn mcpHandler(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
    try ctx.checkDeadline();
    const bridge = try bridgeFrom(ctx);
    const reg_name = ctx.active_tool_name orelse return error.McpMissingToolName;
    const remote = bridge.remote_by_reg.get(reg_name) orelse return error.McpUnknownTool;
    return try bridge.client.callToolOpts(remote, args, .{ .deadline_ms = ctx.deadline_ms });
}

test "registerMcpTools + dispatch via FakeTransport" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fake = mcp_client.FakeTransport.init(allocator);
    defer fake.deinit();

    try fake.enqueueResponse(
        \\{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"t","version":"1"}}}
    );
    try fake.enqueueResponse(
        \\{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","description":"Echo","inputSchema":{"type":"object","properties":{"msg":{"type":"string"}},"required":["msg"]}}]}}
    );
    try fake.enqueueResponse(
        \\{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"{\"echoed\":\"hi\"}"}]}}
    );

    var client = McpClient.initWithTransport(allocator, io, fake.transport());
    defer {
        client.owns_transport_close = false;
        client.deinit();
    }
    try client.initialize();

    var bridge = McpBridge.init(allocator, &client);
    defer bridge.deinit();

    var registry = SkillRegistry.init(allocator, io);
    defer registry.deinit();

    const n = try registerMcpTools(&registry, &bridge, .{ .name_prefix = "mcp." });
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expect(registry.get("mcp.echo") != null);

    var args = std.json.ObjectMap{};
    defer {
        var it = args.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            freeValue(allocator, e.value_ptr.*);
        }
        args.deinit(allocator);
    }
    try args.put(allocator, try allocator.dupe(u8, "msg"), .{ .string = try allocator.dupe(u8, "hi") });

    var ctx = SkillContext{ .allocator = allocator, .backend_ptr = &bridge };
    const result = try registry.dispatchWith("mcp.echo", &ctx, .{ .object = args }, .{});
    defer freeValue(allocator, result);
    try std.testing.expect(result == .object);
    try std.testing.expectEqualStrings("hi", result.object.get("echoed").?.string);
}
