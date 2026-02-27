const std = @import("std");

/// WebSocket 操作码
pub const OpCode = enum(u8) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

/// WebSocket 帧
pub const Frame = struct {
    fin: bool,
    opcode: OpCode,
    masked: bool,
    payload: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Frame) void {
        self.allocator.free(self.payload);
    }

    /// 解析 WebSocket 帧
    pub fn parse(data: []const u8, allocator: std.mem.Allocator) !Frame {
        if (data.len < 2) return error.InvalidFrame;

        const byte1 = data[0];
        const byte2 = data[1];

        const fin = (byte1 & 0x80) != 0;
        const opcode = @as(OpCode, @enumFromInt(byte1 & 0x0F));
        const masked = (byte2 & 0x80) != 0;
        var payload_len: usize = @intCast(byte2 & 0x7F);

        var pos: usize = 2;

        // 扩展长度
        if (payload_len == 126) {
            if (data.len < pos + 2) return error.InvalidFrame;
            payload_len = std.mem.readInt(u16, data[pos..][0..2], .big);
            pos += 2;
        } else if (payload_len == 127) {
            if (data.len < pos + 8) return error.InvalidFrame;
            payload_len = std.mem.readInt(u64, data[pos..][0..8], .big);
            pos += 8;
        }

        // 掩码
        var mask: [4]u8 = undefined;
        if (masked) {
            if (data.len < pos + 4) return error.InvalidFrame;
            @memcpy(&mask, data[pos..][0..4]);
            pos += 4;
        }

        // 载荷
        if (data.len < pos + payload_len) return error.InvalidFrame;
        var payload = try allocator.alloc(u8, payload_len);

        if (masked) {
            for (0..payload_len) |i| {
                payload[i] = data[pos + i] ^ mask[i % 4];
            }
        } else {
            @memcpy(payload, data[pos..][0..payload_len]);
        }

        return Frame{
            .fin = fin,
            .opcode = opcode,
            .masked = masked,
            .payload = payload,
            .allocator = allocator,
        };
    }

    /// 编码 WebSocket 帧
    pub fn encode(self: *const Frame, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        // Byte 1: FIN + opcode
        var byte1: u8 = @intFromEnum(self.opcode);
        if (self.fin) byte1 |= 0x80;
        try buffer.append(byte1);

        // Byte 2: MASK + payload length
        const payload_len = self.payload.len;
        var byte2: u8 = 0; // 服务器发送不需要掩码

        if (payload_len < 126) {
            byte2 |= @intCast(payload_len);
            try buffer.append(byte2);
        } else if (payload_len < 65536) {
            byte2 |= 126;
            try buffer.append(byte2);
            try buffer.append(@intCast((payload_len >> 8) & 0xFF));
            try buffer.append(@intCast(payload_len & 0xFF));
        } else {
            byte2 |= 127;
            try buffer.append(byte2);
            var i: usize = 56;
            while (i >= 0) : (i -= 8) {
                try buffer.append(@intCast((payload_len >> @intCast(i)) & 0xFF));
                if (i == 0) break;
            }
        }

        // Payload
        try buffer.appendSlice(self.payload);

        return buffer.toOwnedSlice();
    }
};

/// WebSocket 连接
pub const WebSocket = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, stream: std.net.Stream) WebSocket {
        return WebSocket{
            .allocator = allocator,
            .stream = stream,
        };
    }

    /// 发送文本消息
    pub fn sendText(self: *WebSocket, text: []const u8) !void {
        const frame = Frame{
            .fin = true,
            .opcode = .text,
            .masked = false,
            .payload = text,
            .allocator = self.allocator,
        };

        const encoded = try frame.encode(self.allocator);
        defer self.allocator.free(encoded);

        try self.stream.writeAll(encoded);
    }

    /// 发送二进制消息
    pub fn sendBinary(self: *WebSocket, data: []const u8) !void {
        const frame = Frame{
            .fin = true,
            .opcode = .binary,
            .masked = false,
            .payload = data,
            .allocator = self.allocator,
        };

        const encoded = try frame.encode(self.allocator);
        defer self.allocator.free(encoded);

        try self.stream.writeAll(encoded);
    }

    /// 发送 Pong
    pub fn sendPong(self: *WebSocket, data: []const u8) !void {
        const frame = Frame{
            .fin = true,
            .opcode = .pong,
            .masked = false,
            .payload = data,
            .allocator = self.allocator,
        };

        const encoded = try frame.encode(self.allocator);
        defer self.allocator.free(encoded);

        try self.stream.writeAll(encoded);
    }

    /// 接收消息
    pub fn receive(self: *WebSocket) !Frame {
        var buffer: [8192]u8 = undefined;
        const n = try self.stream.read(&buffer);

        if (n == 0) {
            self.closed = true;
            return error.ConnectionClosed;
        }

        return try Frame.parse(buffer[0..n], self.allocator);
    }

    /// 关闭连接
    pub fn close(self: *WebSocket) void {
        if (!self.closed) {
            self.stream.close();
            self.closed = true;
        }
    }
};

test "websocket frame encoding" {
    const allocator = std.testing.allocator;

    const frame = Frame{
        .fin = true,
        .opcode = .text,
        .masked = false,
        .payload = "Hello",
        .allocator = allocator,
    };

    const encoded = try frame.encode(allocator);
    defer allocator.free(encoded);

    try std.testing.expect(encoded.len > 0);
    try std.testing.expectEqual(@as(u8, 0x81), encoded[0]); // FIN + TEXT
    try std.testing.expectEqual(@as(u8, 5), encoded[1]); // Length = 5
}
