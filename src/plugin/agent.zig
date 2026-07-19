const std = @import("std");
const Plugin = @import("plugin.zig").Plugin;

/// Minimal MCP-style JSON-RPC tool router.
/// Supports `tools/list` and `tools/call` (also accepts legacy `call_tool`).
pub const AgentPlugin = struct {
    allocator: std.mem.Allocator,
    tools: std.StringHashMap(ToolHandler),

    pub const ToolHandler = *const fn (ctx: *AgentPlugin, params: ?std.json.Value) anyerror!std.json.Value;

    pub fn init(allocator: std.mem.Allocator) AgentPlugin {
        return .{
            .allocator = allocator,
            .tools = std.StringHashMap(ToolHandler).init(allocator),
        };
    }

    pub fn deinit(self: *AgentPlugin) void {
        self.tools.deinit();
    }

    pub fn registerTool(self: *AgentPlugin, name: []const u8, handler: ToolHandler) !void {
        try self.tools.put(name, handler);
    }

    pub fn plugin(self: *AgentPlugin) Plugin {
        return Plugin{
            .name = "AI Agent (MCP)",
            .vtable = &.{
                .start = start,
                .stop = stop,
            },
            .context = self,
        };
    }

    fn start(_: *anyopaque) !void {}

    fn stop(_: *anyopaque) !void {}

    /// Handle a JSON-RPC request body. Caller owns returned buffer.
    pub fn handleRequest(self: *AgentPlugin, request_json: []const u8) ![]const u8 {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, request_json, .{});
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return try errorResponse(self.allocator, null, -32600, "Invalid Request");

        const method_val = root.object.get("method") orelse
            return try errorResponse(self.allocator, null, -32600, "Missing method");
        if (method_val != .string) return try errorResponse(self.allocator, null, -32600, "Invalid method");
        const method = method_val.string;
        const id = root.object.get("id");

        if (std.mem.eql(u8, method, "tools/list") or std.mem.eql(u8, method, "list_tools")) {
            const names = try self.collectToolNames();
            defer self.allocator.free(names);
            return try successResponse(self.allocator, id, .{ .tools = names });
        }

        if (std.mem.eql(u8, method, "tools/call") or std.mem.eql(u8, method, "call_tool")) {
            const params = root.object.get("params") orelse
                return try errorResponse(self.allocator, id, -32602, "Missing params");
            if (params != .object) return try errorResponse(self.allocator, id, -32602, "Invalid params");

            const name_val = params.object.get("name") orelse
                return try errorResponse(self.allocator, id, -32602, "Missing tool name");
            if (name_val != .string) return try errorResponse(self.allocator, id, -32602, "Invalid tool name");

            const handler = self.tools.get(name_val.string) orelse
                return try errorResponse(self.allocator, id, -32601, "Tool not found");

            const args = params.object.get("arguments");
            const result = try handler(self, args);
            return try successResponse(self.allocator, id, result);
        }

        return try errorResponse(self.allocator, id, -32601, "Method not found");
    }

    fn collectToolNames(self: *AgentPlugin) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(self.allocator);
        var it = self.tools.keyIterator();
        while (it.next()) |key| {
            try list.append(self.allocator, key.*);
        }
        return try list.toOwnedSlice(self.allocator);
    }

    fn successResponse(allocator: std.mem.Allocator, id: ?std.json.Value, result: anytype) ![]const u8 {
        return try std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .result = result,
            .id = id,
        }, .{});
    }

    fn errorResponse(allocator: std.mem.Allocator, id: ?std.json.Value, code: i32, message: []const u8) ![]const u8 {
        return try std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .@"error" = .{ .code = code, .message = message },
            .id = id,
        }, .{});
    }
};

test "agent: tools/list and tools/call" {
    const a = std.testing.allocator;
    var agent = AgentPlugin.init(a);
    defer agent.deinit();

    const echo = struct {
        fn run(_: *AgentPlugin, params: ?std.json.Value) anyerror!std.json.Value {
            if (params) |p| {
                if (p == .object) {
                    if (p.object.get("msg")) |m| return m;
                }
            }
            return .{ .string = "empty" };
        }
    }.run;
    try agent.registerTool("echo", echo);

    const list_json = try agent.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    );
    defer a.free(list_json);
    try std.testing.expect(std.mem.indexOf(u8, list_json, "echo") != null);

    const call_json = try agent.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"msg":"hi"}}}
    );
    defer a.free(call_json);
    try std.testing.expect(std.mem.indexOf(u8, call_json, "hi") != null);
}
