const std = @import("std");
const zfinal = @import("../core/zfinal.zig");
const Plugin = @import("plugin.zig").Plugin;
const JsonKit = @import("../kit/json_kit.zig").JsonKit;

/// MCP JSON-RPC Request
pub const McpRequest = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: ?std.json.Value = null,
    id: ?std.json.Value = null,
};

/// MCP JSON-RPC Response
pub const McpResponse = struct {
    jsonrpc: []const u8 = "2.0",
    result: ?std.json.Value = null,
    @"error": ?McpError = null,
    id: ?std.json.Value = null,
};

pub const McpError = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,
};

/// AI Agent Plugin Implementation
pub const AgentPlugin = struct {
    allocator: std.mem.Allocator,
    tools: std.StringHashMap(ToolHandler),

    pub const ToolHandler = *const fn (ctx: *AgentPlugin, params: ?std.json.Value) anyerror!std.json.Value;

    pub fn init(allocator: std.mem.Allocator) AgentPlugin {
        return AgentPlugin{
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

    /// Implement Plugin interface
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

    fn start(ctx: *anyopaque) !void {
        const self: *AgentPlugin = @ptrCast(@alignCast(ctx));
        std.debug.print("Starting AI Agent Plugin (MCP)...\n", .{});

        // Register default tools
        try self.registerTool("list_tools", listTools);

        std.debug.print("AI Agent Plugin started.\n", .{});
    }

    fn stop(ctx: *anyopaque) !void {
        _ = ctx;
        std.debug.print("AI Agent Plugin stopped.\n", .{});
    }

    /// Handle MCP Request
    pub fn handleRequest(self: *AgentPlugin, request_json: []const u8) ![]const u8 {
        const req = try std.json.parseFromSlice(McpRequest, self.allocator, request_json, .{ .ignore_unknown_fields = true });
        defer req.deinit();

        if (std.mem.eql(u8, req.value.method, "call_tool")) {
            if (req.value.params) |params| {
                if (params.object.get("name")) |tool_name_val| {
                    if (tool_name_val == .string) {
                        const tool_name = tool_name_val.string;
                        if (self.tools.get(tool_name)) |handler| {
                            const args = params.object.get("arguments");
                            const result = try handler(self, args);

                            // Construct response
                            // Note: Simplified response construction
                            return try std.json.stringifyAlloc(self.allocator, McpResponse{
                                .result = result,
                                .id = req.value.id,
                            }, .{});
                        }
                    }
                }
            }
        }

        return try std.json.stringifyAlloc(self.allocator, McpResponse{
            .@"error" = .{ .code = -32601, .message = "Method not found" },
            .id = req.value.id,
        }, .{});
    }

    // Default Tools
    fn listTools(self: *AgentPlugin, params: ?std.json.Value) !std.json.Value {
        _ = params;
        var list = std.ArrayList([]const u8).init(self.allocator);
        defer list.deinit();

        var it = self.tools.keyIterator();
        while (it.next()) |key| {
            try list.append(key.*);
        }

        // Return list of tool names
        // In a real implementation, this would return full tool schemas
        return std.json.Value{ .array = std.ArrayList(std.json.Value).init(self.allocator) }; // Placeholder
    }
};
