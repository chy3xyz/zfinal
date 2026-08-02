//! Offline MCP bridge demo: FakeTransport → McpBridge → SkillRegistry.dispatch.
//! No live LLM / no child process. Run: `zig build run-ai-mcp`

const std = @import("std");
const zfinal = @import("zfinal");

pub fn main(init: std.process.Init) !void {
    @import("zfinal").io_instance.init(init);
    const allocator = init.gpa;
    const io = init.io;

    var fake = zfinal.ai.McpFakeTransport.init(allocator);
    defer fake.deinit();

    try fake.enqueueResponse(
        \\{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"demo","version":"1"}}}
    );
    try fake.enqueueResponse(
        \\{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"ignored"}}
    );
    try fake.enqueueResponse(
        \\{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","description":"Echo msg","inputSchema":{"type":"object","properties":{"msg":{"type":"string"}},"required":["msg"]}}],"nextCursor":"p2"}}
    );
    try fake.enqueueResponse(
        \\{"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"add","description":"Add two numbers","inputSchema":{"type":"object","properties":{"a":{"type":"number"},"b":{"type":"number"}},"required":["a","b"]}}]}}
    );
    try fake.enqueueResponse(
        \\{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"{\"echoed\":\"hello-mcp\"}"}]}}
    );

    var client = zfinal.ai.McpClient.initWithTransport(allocator, io, fake.transport());
    defer {
        client.owns_transport_close = false;
        client.deinit();
    }
    try client.initialize();

    var bridge = zfinal.ai.McpBridge.init(allocator, &client);
    defer bridge.deinit();

    var registry = zfinal.ai.SkillRegistry.init(allocator, io);
    defer registry.deinit();

    const n = try bridge.registerInto(&registry, .{
        .name_prefix = "mcp.",
        .allowlist = &.{ "echo", "add" },
        .timeout_ms = 5_000,
    });
    if (n != 2) return error.UnexpectedToolCount;
    std.debug.print("registered {d} MCP tools (paginated list + skipped notification)\n", .{n});

    var args = std.json.ObjectMap{};
    defer {
        var it = args.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            zfinal.ai.freeValue(allocator, e.value_ptr.*);
        }
        args.deinit(allocator);
    }
    try args.put(allocator, try allocator.dupe(u8, "msg"), .{ .string = try allocator.dupe(u8, "hello-mcp") });

    var ctx = zfinal.ai.SkillContext{ .allocator = allocator, .backend_ptr = &bridge };
    const result = try registry.dispatchWith("mcp.echo", &ctx, .{ .object = args }, .{});
    defer zfinal.ai.freeValue(allocator, result);

    const echoed = result.object.get("echoed").?.string;
    std.debug.print("mcp.echo → {s}\n", .{echoed});
    std.debug.print("ok — AgentPlugin ≠ McpClient: use AgentPlugin for in-process tools/list server;\n", .{});
    std.debug.print("     use McpClient+McpBridge to import an external MCP server into SkillRegistry.\n", .{});
}
