const std = @import("std");
const Plugin = @import("plugin.zig").Plugin;

/// Minimal MCP-style JSON-RPC router.
/// Supports tools/list|call, resources/list|read, prompts/list|get
/// (also accepts legacy `list_tools` / `call_tool`).
pub const AgentPlugin = struct {
    allocator: std.mem.Allocator,
    tools: std.StringHashMap(ToolHandler),
    resources: std.StringHashMap(ResourceEntry),
    prompts: std.StringHashMap(PromptEntry),

    pub const ToolHandler = *const fn (ctx: *AgentPlugin, params: ?std.json.Value) anyerror!std.json.Value;
    pub const ResourceHandler = *const fn (ctx: *AgentPlugin, uri: []const u8) anyerror![]const u8;
    pub const PromptHandler = *const fn (ctx: *AgentPlugin, name: []const u8, arguments: ?std.json.Value) anyerror!std.json.Value;

    pub const ResourceEntry = struct {
        name: []const u8,
        description: []const u8,
        mime_type: []const u8,
        handler: ResourceHandler,
    };

    pub const PromptEntry = struct {
        description: []const u8,
        handler: PromptHandler,
    };

    pub fn init(allocator: std.mem.Allocator) AgentPlugin {
        return .{
            .allocator = allocator,
            .tools = std.StringHashMap(ToolHandler).init(allocator),
            .resources = std.StringHashMap(ResourceEntry).init(allocator),
            .prompts = std.StringHashMap(PromptEntry).init(allocator),
        };
    }

    pub fn deinit(self: *AgentPlugin) void {
        self.tools.deinit();
        self.resources.deinit();
        self.prompts.deinit();
    }

    pub fn registerTool(self: *AgentPlugin, name: []const u8, handler: ToolHandler) !void {
        try self.tools.put(name, handler);
    }

    pub fn registerResource(
        self: *AgentPlugin,
        uri: []const u8,
        name: []const u8,
        description: []const u8,
        mime_type: []const u8,
        handler: ResourceHandler,
    ) !void {
        try self.resources.put(uri, .{
            .name = name,
            .description = description,
            .mime_type = mime_type,
            .handler = handler,
        });
    }

    pub fn registerPrompt(self: *AgentPlugin, name: []const u8, description: []const u8, handler: PromptHandler) !void {
        try self.prompts.put(name, .{ .description = description, .handler = handler });
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
            return try self.listToolsResponse(id);
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

        if (std.mem.eql(u8, method, "resources/list")) {
            return try self.listResourcesResponse(id);
        }

        if (std.mem.eql(u8, method, "resources/read")) {
            const params = root.object.get("params") orelse
                return try errorResponse(self.allocator, id, -32602, "Missing params");
            if (params != .object) return try errorResponse(self.allocator, id, -32602, "Invalid params");
            const uri_val = params.object.get("uri") orelse
                return try errorResponse(self.allocator, id, -32602, "Missing uri");
            if (uri_val != .string) return try errorResponse(self.allocator, id, -32602, "Invalid uri");
            const entry = self.resources.get(uri_val.string) orelse
                return try errorResponse(self.allocator, id, -32601, "Resource not found");
            const text = try entry.handler(self, uri_val.string);
            // Build MCP resources/read result
            return try successResponse(self.allocator, id, .{
                .contents = .{
                    .{
                        .uri = uri_val.string,
                        .mimeType = entry.mime_type,
                        .text = text,
                    },
                },
            });
        }

        if (std.mem.eql(u8, method, "prompts/list")) {
            return try self.listPromptsResponse(id);
        }

        if (std.mem.eql(u8, method, "prompts/get")) {
            const params = root.object.get("params") orelse
                return try errorResponse(self.allocator, id, -32602, "Missing params");
            if (params != .object) return try errorResponse(self.allocator, id, -32602, "Invalid params");
            const name_val = params.object.get("name") orelse
                return try errorResponse(self.allocator, id, -32602, "Missing prompt name");
            if (name_val != .string) return try errorResponse(self.allocator, id, -32602, "Invalid prompt name");
            const entry = self.prompts.get(name_val.string) orelse
                return try errorResponse(self.allocator, id, -32601, "Prompt not found");
            const arguments = params.object.get("arguments");
            const messages = try entry.handler(self, name_val.string, arguments);
            return try successResponse(self.allocator, id, .{ .messages = messages });
        }

        return try errorResponse(self.allocator, id, -32601, "Method not found");
    }

    /// MCP-compatible tools/list: `{ tools: [{ name, description, inputSchema }] }`.
    fn listToolsResponse(self: *AgentPlugin, id: ?std.json.Value) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"result\":{\"tools\":[");
        var first = true;
        var it = self.tools.keyIterator();
        while (it.next()) |key| {
            if (!first) try buf.append(self.allocator, ',');
            first = false;
            try buf.appendSlice(self.allocator, "{\"name\":");
            try appendJsonStr(&buf, self.allocator, key.*);
            try buf.appendSlice(self.allocator, ",\"description\":");
            try appendJsonStr(&buf, self.allocator, key.*);
            try buf.appendSlice(self.allocator, ",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}");
        }
        try buf.appendSlice(self.allocator, "]},\"id\":");
        try appendId(&buf, self.allocator, id);
        try buf.append(self.allocator, '}');
        return try buf.toOwnedSlice(self.allocator);
    }

    fn listResourcesResponse(self: *AgentPlugin, id: ?std.json.Value) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"result\":{\"resources\":[");
        var first = true;
        var it = self.resources.iterator();
        while (it.next()) |e| {
            if (!first) try buf.append(self.allocator, ',');
            first = false;
            try buf.appendSlice(self.allocator, "{\"uri\":");
            try appendJsonStr(&buf, self.allocator, e.key_ptr.*);
            try buf.appendSlice(self.allocator, ",\"name\":");
            try appendJsonStr(&buf, self.allocator, e.value_ptr.name);
            try buf.appendSlice(self.allocator, ",\"description\":");
            try appendJsonStr(&buf, self.allocator, e.value_ptr.description);
            try buf.appendSlice(self.allocator, ",\"mimeType\":");
            try appendJsonStr(&buf, self.allocator, e.value_ptr.mime_type);
            try buf.append(self.allocator, '}');
        }
        try buf.appendSlice(self.allocator, "]},\"id\":");
        try appendId(&buf, self.allocator, id);
        try buf.append(self.allocator, '}');
        return try buf.toOwnedSlice(self.allocator);
    }

    fn listPromptsResponse(self: *AgentPlugin, id: ?std.json.Value) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"result\":{\"prompts\":[");
        var first = true;
        var it = self.prompts.iterator();
        while (it.next()) |e| {
            if (!first) try buf.append(self.allocator, ',');
            first = false;
            try buf.appendSlice(self.allocator, "{\"name\":");
            try appendJsonStr(&buf, self.allocator, e.key_ptr.*);
            try buf.appendSlice(self.allocator, ",\"description\":");
            try appendJsonStr(&buf, self.allocator, e.value_ptr.description);
            try buf.append(self.allocator, '}');
        }
        try buf.appendSlice(self.allocator, "]},\"id\":");
        try appendId(&buf, self.allocator, id);
        try buf.append(self.allocator, '}');
        return try buf.toOwnedSlice(self.allocator);
    }

    fn appendId(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, id: ?std.json.Value) !void {
        if (id) |ivid| {
            const id_json = try std.json.Stringify.valueAlloc(allocator, ivid, .{});
            defer allocator.free(id_json);
            try buf.appendSlice(allocator, id_json);
        } else {
            try buf.appendSlice(allocator, "null");
        }
    }

    fn appendJsonStr(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
        try buf.append(allocator, '"');
        for (s) |c| {
            switch (c) {
                '"' => try buf.appendSlice(allocator, "\\\""),
                '\\' => try buf.appendSlice(allocator, "\\\\"),
                '\n' => try buf.appendSlice(allocator, "\\n"),
                '\r' => try buf.appendSlice(allocator, "\\r"),
                '\t' => try buf.appendSlice(allocator, "\\t"),
                else => try buf.append(allocator, c),
            }
        }
        try buf.append(allocator, '"');
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
    try std.testing.expect(std.mem.indexOf(u8, list_json, "inputSchema") != null);

    const call_json = try agent.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"msg":"hi"}}}
    );
    defer a.free(call_json);
    try std.testing.expect(std.mem.indexOf(u8, call_json, "hi") != null);
}

test "agent: resources and prompts" {
    const a = std.testing.allocator;
    var agent = AgentPlugin.init(a);
    defer agent.deinit();

    const read = struct {
        fn run(_: *AgentPlugin, _: []const u8) anyerror![]const u8 {
            return "resource-body";
        }
    }.run;
    try agent.registerResource("file:///x", "x", "demo", "text/plain", read);

    const greet = struct {
        fn run(_: *AgentPlugin, _: []const u8, _: ?std.json.Value) anyerror!std.json.Value {
            return .{ .string = "prompt-ok" };
        }
    }.run;
    try agent.registerPrompt("greet", "Say hi", greet);

    const rl = try agent.handleRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"resources/list"}
    );
    defer a.free(rl);
    try std.testing.expect(std.mem.indexOf(u8, rl, "file:///x") != null);

    const rr = try agent.handleRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"file:///x"}}
    );
    defer a.free(rr);
    try std.testing.expect(std.mem.indexOf(u8, rr, "resource-body") != null);

    const pl = try agent.handleRequest(
        \\{"jsonrpc":"2.0","id":3,"method":"prompts/list"}
    );
    defer a.free(pl);
    try std.testing.expect(std.mem.indexOf(u8, pl, "greet") != null);

    const pg = try agent.handleRequest(
        \\{"jsonrpc":"2.0","id":4,"method":"prompts/get","params":{"name":"greet"}}
    );
    defer a.free(pg);
    try std.testing.expect(std.mem.indexOf(u8, pg, "prompt-ok") != null);
}
