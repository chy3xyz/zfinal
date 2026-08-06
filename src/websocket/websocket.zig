const std = @import("std");
const io_instance = @import("../io_instance.zig");
const logger = @import("../core/logger.zig");
const sockread = @import("../core/sockread.zig");

/// Max WebSocket payload accepted by `receive` (1 MiB).
pub const max_payload_len: usize = 1024 * 1024;

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

    /// Parse one frame from `data`. When `require_client_mask` is true (server
    /// receive path), RSV bits must be 0, MASK must be set, and payload ≤ `max_payload_len`.
    pub fn parse(data: []const u8, allocator: std.mem.Allocator) !Frame {
        return parseOpts(data, allocator, .{ .require_client_mask = false });
    }

    pub const ParseOpts = struct {
        require_client_mask: bool = false,
    };

    pub fn parseOpts(data: []const u8, allocator: std.mem.Allocator, opts: ParseOpts) !Frame {
        if (data.len < 2) return error.InvalidFrame;

        const byte1 = data[0];
        const byte2 = data[1];

        if ((byte1 & 0x70) != 0) return error.RsvBitsSet;
        const fin = (byte1 & 0x80) != 0;
        const opcode = @as(OpCode, @enumFromInt(byte1 & 0x0F));
        const masked = (byte2 & 0x80) != 0;
        if (opts.require_client_mask and !masked) return error.MaskRequired;
        var payload_len: usize = @intCast(byte2 & 0x7F);

        var pos: usize = 2;

        if (payload_len == 126) {
            if (data.len < pos + 2) return error.InvalidFrame;
            payload_len = std.mem.readInt(u16, data[pos..][0..2], .big);
            pos += 2;
        } else if (payload_len == 127) {
            if (data.len < pos + 8) return error.InvalidFrame;
            payload_len = std.mem.readInt(u64, data[pos..][0..8], .big);
            pos += 8;
        }

        if (payload_len > max_payload_len) return error.PayloadTooLarge;

        var mask: [4]u8 = undefined;
        if (masked) {
            if (data.len < pos + 4) return error.InvalidFrame;
            @memcpy(&mask, data[pos..][0..4]);
            pos += 4;
        }

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
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(allocator);

        // Byte 1: FIN + opcode
        var byte1: u8 = @intFromEnum(self.opcode);
        if (self.fin) byte1 |= 0x80;
        try buffer.append(allocator, byte1);

        // Byte 2: MASK + payload length
        const payload_len = self.payload.len;
        var byte2: u8 = 0; // 服务器发送不需要掩码

        if (payload_len < 126) {
            byte2 |= @intCast(payload_len);
            try buffer.append(allocator, byte2);
        } else if (payload_len < 65536) {
            byte2 |= 126;
            try buffer.append(allocator, byte2);
            try buffer.append(allocator, @intCast((payload_len >> 8) & 0xFF));
            try buffer.append(allocator, @intCast(payload_len & 0xFF));
        } else {
            byte2 |= 127;
            try buffer.append(allocator, byte2);
            var i: usize = 56;
            while (i >= 0) : (i -= 8) {
                try buffer.append(allocator, @intCast((payload_len >> @intCast(i)) & 0xFF));
                if (i == 0) break;
            }
        }

        // Payload
        try buffer.appendSlice(allocator, self.payload);

        return buffer.toOwnedSlice(allocator);
    }
};

/// WebSocket 连接
pub const WebSocket = struct {
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    closed: bool = false,
    close_sent: bool = false,
    /// Buffer for reassembling fragmented messages.
    frag_buf: std.ArrayList(u8) = undefined,
    frag_opcode: OpCode = .text,
    /// 4KB sockread cache — small frames share one refill (header/mask/payload).
    read_buf: [4096]u8 = undefined,
    buf_reader: ?sockread.BufReader = null,
    /// Mono ms of last successful read/write (for idle checks).
    last_activity_ms: i64 = 0,
    /// Close with 1001 when idle longer than this (0 = disabled).
    idle_timeout_ms: i64 = 0,
    /// Handshake request target (path + query, e.g. `/ws?room_id=42`), owned.
    /// Set by the server during the upgrade; powers `queryParam`.
    handshake_target: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, stream: std.Io.net.Stream) WebSocket {
        return .{
            .allocator = allocator,
            .stream = stream,
            .frag_buf = std.ArrayList(u8).empty,
            .last_activity_ms = monoMs(),
        };
    }

    fn monoMs() i64 {
        return @import("../kit/time_kit.zig").TimeKit.nowMillis();
    }

    fn touch(self: *WebSocket) void {
        self.last_activity_ms = monoMs();
    }

    /// True when `idle_timeout_ms > 0` and no activity within the window.
    pub fn isIdle(self: *const WebSocket) bool {
        if (self.idle_timeout_ms <= 0) return false;
        return monoMs() - self.last_activity_ms >= self.idle_timeout_ms;
    }

    /// If idle, send close 1001 and mark closed. Returns true when closed due to idle.
    pub fn closeIfIdle(self: *WebSocket) bool {
        if (!self.isIdle()) return false;
        self.sendClose(1001, "idle timeout");
        self.close();
        return true;
    }

    pub fn deinit(self: *WebSocket) void {
        if (self.handshake_target) |t| self.allocator.free(t);
        self.frag_buf.deinit(self.allocator);
        self.close();
    }

    /// Parse a query parameter from a handshake target like `/ws?room_id=42`.
    /// Borrows `target`; no allocation. RFC 3986 percent-encoding is NOT
    /// decoded — use `std.Uri` if you need that.
    pub fn queryParamFromTarget(target: []const u8, name: []const u8) ?[]const u8 {
        const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
        var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
        }
        return null;
    }

    /// Query parameter from the handshake URL (e.g. `ws.queryParam("room_id")`).
    pub fn queryParam(self: *const WebSocket, name: []const u8) ?[]const u8 {
        const target = self.handshake_target orelse return null;
        return queryParamFromTarget(target, name);
    }

    fn frameReader(self: *WebSocket) *sockread.BufReader {
        if (self.buf_reader == null) {
            self.buf_reader = sockread.BufReader.init(self.stream, &self.read_buf);
        }
        return &self.buf_reader.?;
    }

    fn readExact(self: *WebSocket, out: []u8) !void {
        self.frameReader().readFull(out) catch |err| switch (err) {
            error.ConnectionClosed => {
                self.closed = true;
                return error.ConnectionClosed;
            },
            else => return error.ConnectionError,
        };
    }

    fn writeFrame(self: *WebSocket, opcode: OpCode, data: []const u8) !void {
        if (self.closed) return error.ConnectionClosed;
        const frame = Frame{ .fin = true, .opcode = opcode, .masked = false, .payload = data, .allocator = self.allocator };
        const encoded = try frame.encode(self.allocator);
        defer self.allocator.free(encoded);
        var write_buf: [4096]u8 = undefined;
        var writer = self.stream.writer(io_instance.io, &write_buf);
        try writer.interface.writeAll(encoded);
        try writer.interface.flush();
        self.touch();
    }

    /// 发送文本消息
    pub fn sendText(self: *WebSocket, text: []const u8) !void {
        try self.writeFrame(.text, text);
    }

    /// 发送二进制消息
    pub fn sendBinary(self: *WebSocket, data: []const u8) !void {
        try self.writeFrame(.binary, data);
    }

    /// 发送 Ping (best-effort, failures logged at debug level)
    pub fn sendPing(self: *WebSocket, data: []const u8) void {
        self.writeFrame(.ping, data) catch |err| {
            logger.getLogger().debugFmt("ws: ping write failed: {t}", .{err});
        };
    }

    /// 发送 Pong (best-effort, failures logged at debug level)
    pub fn sendPong(self: *WebSocket, data: []const u8) void {
        self.writeFrame(.pong, data) catch |err| {
            logger.getLogger().debugFmt("ws: pong write failed: {t}", .{err});
        };
    }

    /// Send a large message as fragmented frames (chunked at ~4KB boundaries).
    /// Use this for messages > 8KB to avoid buffer overflow at the receiver.
    pub fn sendFragmented(self: *WebSocket, opcode: OpCode, data: []const u8) !void {
        const chunk_size = 4096;
        var offset: usize = 0;
        while (offset < data.len) {
            const end = @min(offset + chunk_size, data.len);
            const fin = end >= data.len;
            const chunk_opcode: OpCode = if (offset == 0) opcode else .continuation;

            const frame = Frame{ .fin = fin, .opcode = chunk_opcode, .masked = false, .payload = data[offset..end], .allocator = self.allocator };
            const encoded = try frame.encode(self.allocator);
            defer self.allocator.free(encoded);
            var wbuf: [4096]u8 = undefined;
            var writer = self.stream.writer(io_instance.io, &wbuf);
            try writer.interface.writeAll(encoded);
            try writer.interface.flush();
            offset = end;
        }
    }

    /// Send close frame with status code and optional reason.
    pub fn sendClose(self: *WebSocket, code: u16, reason: []const u8) void {
        if (self.close_sent) return;
        self.close_sent = true;

        var buf: [125]u8 = undefined;
        std.mem.writeInt(u16, buf[0..2], code, .big);
        const len = @min(reason.len, buf.len - 2);
        @memcpy(buf[2..][0..len], reason[0..len]);
        self.writeFrame(.close, buf[0 .. 2 + len]) catch |err| {
            logger.getLogger().debugFmt("ws: close frame write failed: {t}", .{err});
        };
    }

    /// Read one RFC 6455 frame via buffered sockread (bypasses Threaded Io net_read).
    /// Server path: rejects RSV≠0 and unmasked client frames.
    fn readFrame(self: *WebSocket) !Frame {
        var header: [2]u8 = undefined;
        try self.readExact(&header);

        if ((header[0] & 0x70) != 0) return error.RsvBitsSet;
        const fin = (header[0] & 0x80) != 0;
        const opcode: OpCode = @enumFromInt(header[0] & 0x0F);
        const masked = (header[1] & 0x80) != 0;
        if (!masked) return error.MaskRequired;
        var payload_len: usize = header[1] & 0x7F;

        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            try self.readExact(&ext);
            payload_len = std.mem.readInt(u16, &ext, .big);
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            try self.readExact(&ext);
            payload_len = @intCast(std.mem.readInt(u64, &ext, .big));
        }

        if (payload_len > max_payload_len) return error.PayloadTooLarge;

        var mask: [4]u8 = undefined;
        try self.readExact(&mask);

        const payload = try self.allocator.alloc(u8, payload_len);
        errdefer self.allocator.free(payload);
        if (payload_len > 0) {
            try self.readExact(payload);
        }
        for (payload, 0..) |*b, i| {
            b.* ^= mask[i % 4];
        }

        return .{
            .fin = fin,
            .opcode = opcode,
            .masked = true,
            .payload = payload,
            .allocator = self.allocator,
        };
    }

    /// 接收消息. Returns Frame on success. Caller must frame.deinit().
    /// Handles fragmented messages transparently — reassembles continuation frames.
    ///
    /// Frame pieces are read through `sockread.BufReader` (posix `read`, no Io
    /// `net_read`) so small frames share one refill across header/mask/payload.
    pub fn receive(self: *WebSocket) !Frame {
        if (self.closeIfIdle()) return error.ConnectionClosed;
        while (true) {
            var frame = try self.readFrame();
            self.touch();

            switch (frame.opcode) {
                .ping => {
                    self.sendPong(frame.payload);
                    frame.deinit();
                    continue;
                },
                .pong => {
                    frame.deinit();
                    continue;
                },
                .close => {
                    self.sendClose(1000, "");
                    self.close();
                    frame.deinit();
                    return error.ConnectionClosed;
                },
                .continuation => {
                    const fin = frame.fin;
                    try self.frag_buf.appendSlice(self.allocator, frame.payload);
                    frame.deinit();
                    if (fin) {
                        const complete = try self.allocator.dupe(u8, self.frag_buf.items);
                        self.frag_buf.clearRetainingCapacity();
                        return Frame{
                            .fin = true,
                            .opcode = self.frag_opcode,
                            .masked = false,
                            .payload = complete,
                            .allocator = self.allocator,
                        };
                    }
                    continue;
                },
                else => {
                    if (!frame.fin) {
                        self.frag_opcode = frame.opcode;
                        try self.frag_buf.appendSlice(self.allocator, frame.payload);
                        frame.deinit();
                        continue;
                    }
                    return frame;
                },
            }
        }
    }

    /// 关闭连接
    pub fn close(self: *WebSocket) void {
        if (!self.closed) {
            self.stream.close(io_instance.io);
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

test "websocket frame parse masked roundtrip" {
    const allocator = std.testing.allocator;
    // FIN+TEXT, MASK, len=5, mask=01020304, payload "Hello" xor mask
    const raw = [_]u8{ 0x81, 0x85, 0x01, 0x02, 0x03, 0x04, 0x48 ^ 0x01, 0x65 ^ 0x02, 0x6c ^ 0x03, 0x6c ^ 0x04, 0x6f ^ 0x01 };
    var frame = try Frame.parseOpts(&raw, allocator, .{ .require_client_mask = true });
    defer frame.deinit();
    try std.testing.expectEqualStrings("Hello", frame.payload);
}

test "websocket frame parse rejects unmasked when required" {
    const allocator = std.testing.allocator;
    const raw = [_]u8{ 0x81, 0x05, 'H', 'e', 'l', 'l', 'o' };
    try std.testing.expectError(error.MaskRequired, Frame.parseOpts(&raw, allocator, .{ .require_client_mask = true }));
}

test "websocket frame parse rejects rsv" {
    const allocator = std.testing.allocator;
    const raw = [_]u8{ 0x91, 0x85, 0, 0, 0, 0, 'H', 'e', 'l', 'l', 'o' }; // RSV1 + TEXT + masked
    try std.testing.expectError(error.RsvBitsSet, Frame.parseOpts(&raw, allocator, .{ .require_client_mask = true }));
}

test "queryParamFromTarget parses handshake query" {
    try std.testing.expectEqualStrings("42", WebSocket.queryParamFromTarget("/ws?room_id=42&token=abc", "room_id").?);
    try std.testing.expectEqualStrings("abc", WebSocket.queryParamFromTarget("/ws?room_id=42&token=abc", "token").?);
    try std.testing.expect(WebSocket.queryParamFromTarget("/ws?room_id=42", "missing") == null);
    try std.testing.expect(WebSocket.queryParamFromTarget("/ws", "room_id") == null);
    try std.testing.expectEqualStrings("", WebSocket.queryParamFromTarget("/ws?room_id=", "room_id").?);
}
