const std = @import("std");
const zfinal = @import("zfinal");

/// WebSocket Echo 示例
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("==============================================\n", .{});
    std.debug.print("  🔌 WebSocket Echo Server\n", .{});
    std.debug.print("==============================================\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Server: ws://localhost:8080/ws\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Test with JavaScript:\n", .{});
    std.debug.print("  const ws = new WebSocket('ws://localhost:8080/ws');\n", .{});
    std.debug.print("  ws.onmessage = (e) => console.log(e.data);\n", .{});
    std.debug.print("  ws.send('Hello WebSocket!');\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Or use wscat:\n", .{});
    std.debug.print("  npm install -g wscat\n", .{});
    std.debug.print("  wscat -c ws://localhost:8080/ws\n", .{});
    std.debug.print("\n", .{});

    // 创建 WebSocket 管理器
    var ws_manager = zfinal.WebSocketManager.init(allocator);
    defer ws_manager.deinit();

    // 添加 WebSocket 路由
    try ws_manager.addRoute("/ws", echoHandler);

    // 启动服务器（简化版，实际需要集成到 ZFinal）
    const address = try std.net.Address.parseIp("127.0.0.1", 8080);
    var listener = try address.listen(.{});
    defer listener.deinit();

    std.debug.print("Listening on port 8080...\n\n", .{});

    while (true) {
        const connection = try listener.accept();

        // 在新线程中处理连接
        const thread = try std.Thread.spawn(.{}, handleConnection, .{ allocator, connection, &ws_manager });
        thread.detach();
    }
}

/// Echo 处理器
fn echoHandler(ws: *zfinal.WebSocket) !void {
    std.debug.print("WebSocket connected\n", .{});

    while (true) {
        var frame = ws.receive() catch |err| {
            if (err == error.ConnectionClosed) {
                std.debug.print("WebSocket disconnected\n", .{});
                break;
            }
            return err;
        };
        defer frame.deinit();

        switch (frame.opcode) {
            .text => {
                std.debug.print("Received: {s}\n", .{frame.payload});

                // Echo 回消息
                var response_buf: [1024]u8 = undefined;
                const response = try std.fmt.bufPrint(&response_buf, "Echo: {s}", .{frame.payload});
                try ws.sendText(response);
            },
            .binary => {
                std.debug.print("Received binary: {} bytes\n", .{frame.payload.len});
                try ws.sendBinary(frame.payload);
            },
            .ping => {
                try ws.sendPong(frame.payload);
            },
            .close => {
                std.debug.print("Close frame received\n", .{});
                break;
            },
            else => {},
        }
    }
}

/// 处理连接
fn handleConnection(allocator: std.mem.Allocator, connection: std.net.Server.Connection, manager: *zfinal.WebSocketManager) !void {
    defer connection.stream.close();

    // 读取 HTTP 请求
    var buffer: [4096]u8 = undefined;
    const n = try connection.stream.read(&buffer);
    const request = buffer[0..n];

    // 检查是否是 WebSocket 升级请求
    if (!std.mem.containsAtLeast(u8, request, 1, "Upgrade: websocket")) {
        try connection.stream.writeAll("HTTP/1.1 400 Bad Request\r\n\r\n");
        return;
    }

    // 提取 Sec-WebSocket-Key
    const key_prefix = "Sec-WebSocket-Key: ";
    const key_start = std.mem.indexOf(u8, request, key_prefix) orelse return error.NoWebSocketKey;
    const key_begin = key_start + key_prefix.len;
    const key_end = std.mem.indexOfScalarPos(u8, request, key_begin, '\r') orelse return error.InvalidKey;
    const key = request[key_begin..key_end];

    // 计算 Sec-WebSocket-Accept
    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var combined_buf: [256]u8 = undefined;
    const combined = try std.fmt.bufPrint(&combined_buf, "{s}{s}", .{ key, magic });

    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(combined, &hash, .{});

    const encoder = std.base64.standard.Encoder;
    var accept_buf: [64]u8 = undefined;
    const accept = encoder.encode(&accept_buf, &hash);

    // 发送 WebSocket 握手响应
    var response_buf: [512]u8 = undefined;
    const response = try std.fmt.bufPrint(&response_buf,
        \\HTTP/1.1 101 Switching Protocols
        \\Upgrade: websocket
        \\Connection: Upgrade
        \\Sec-WebSocket-Accept: {s}
        \\
        \\
    , .{accept});

    try connection.stream.writeAll(response);

    // 创建 WebSocket 连接
    const ws = try allocator.create(zfinal.WebSocket);
    ws.* = zfinal.WebSocket.init(allocator, connection.stream);
    defer allocator.destroy(ws);

    try manager.addConnection(ws);
    defer manager.removeConnection(ws);

    // 查找并执行处理器
    if (manager.findRoute("/ws")) |handler| {
        try handler(ws);
    }
}
