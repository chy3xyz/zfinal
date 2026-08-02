const std = @import("std");
const io_instance = @import("../io_instance.zig");
const sockread = @import("../core/sockread.zig");
const Plugin = @import("plugin.zig").Plugin;

/// MQTT 3.1.1 client configuration (TCP + optional native TLS).
pub const MqttConfig = struct {
    broker_host: []const u8,
    broker_port: u16 = 1883,
    client_id: []const u8,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    keep_alive: u16 = 60,
    use_tls: bool = false,
    /// Skip CA verification (encrypted but not authenticated). Prefer false in production.
    tls_insecure: bool = false,
    /// SNI / host verification name; defaults to broker_host when null.
    tls_server_name: ?[]const u8 = null,
};

const TlsSession = struct {
    client: std.crypto.tls.Client,
    stream_reader: sockread.TimedIoReader,
    stream_writer: std.Io.net.Stream.Writer,
    buffers: []u8,
};

/// Stable MQTT 3.1.1 client: CONNECT / CONNACK / PUBLISH QoS0 / PINGREQ / DISCONNECT.
/// Subscribe + QoS>0 are not implemented yet (use a dedicated broker client if needed).
pub const MqttPlugin = struct {
    allocator: std.mem.Allocator,
    config: MqttConfig,
    stream: ?std.Io.net.Stream = null,
    tls: ?TlsSession = null,
    connected: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: MqttConfig) MqttPlugin {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *MqttPlugin) void {
        self.disconnect();
    }

    pub fn plugin(self: *MqttPlugin) Plugin {
        return Plugin{
            .name = "MQTT",
            .vtable = &.{
                .start = start,
                .stop = stop,
            },
            .context = self,
        };
    }

    fn start(_: *anyopaque) !void {
        // Connection is explicit via `connect()` so apps can start without a live broker.
    }

    fn stop(ctx: *anyopaque) !void {
        const self: *MqttPlugin = @ptrCast(@alignCast(ctx));
        self.disconnect();
    }

    pub fn connect(self: *MqttPlugin) !void {
        if (self.connected) return;
        const address = try std.Io.net.IpAddress.parseIp4(self.config.broker_host, self.config.broker_port);
        self.stream = try address.connect(io_instance.io, .{ .mode = .stream });
        errdefer self.disconnect();

        if (self.config.use_tls) {
            try self.initTls();
        }

        try self.sendConnect();
        try self.readConnack();
        self.connected = true;
    }

    fn initTls(self: *MqttPlugin) !void {
        const stream = self.stream orelse return error.NotConnected;
        const min = std.crypto.tls.Client.min_buffer_len;
        const bufs = try self.allocator.alloc(u8, min * 4);
        errdefer self.allocator.free(bufs);

        var off: usize = 0;
        const stream_read_buf = bufs[off..][0..min];
        off += min;
        const stream_write_buf = bufs[off..][0..min];
        off += min;
        const tls_read_buf = bufs[off..][0..min];
        off += min;
        const tls_write_buf = bufs[off..][0..min];

        var stream_reader = sockread.TimedIoReader.init(stream, stream_read_buf, 0);
        var stream_writer = stream.writer(io_instance.io, stream_write_buf);

        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        io_instance.io.random(&entropy);

        const server_name = self.config.tls_server_name orelse self.config.broker_host;
        const tls_client = std.crypto.tls.Client.init(
            &stream_reader.interface,
            &stream_writer.interface,
            .{
                .host = .{ .explicit = server_name },
                .ca = if (self.config.tls_insecure) .no_verification else .self_signed,
                .read_buffer = tls_read_buf,
                .write_buffer = tls_write_buf,
                .entropy = &entropy,
                .realtime_now = std.Io.Timestamp.now(io_instance.io, .real),
            },
        ) catch |err| {
            self.allocator.free(bufs);
            return err;
        };

        self.tls = .{
            .client = tls_client,
            .stream_reader = stream_reader,
            .stream_writer = stream_writer,
            .buffers = bufs,
        };
    }

    pub fn disconnect(self: *MqttPlugin) void {
        if (self.connected) {
            self.writeAll(&[_]u8{ 0xE0, 0x00 }) catch {};
        }
        if (self.tls) |*tls| {
            self.allocator.free(tls.buffers);
            self.tls = null;
        }
        if (self.stream) |s| {
            s.close(io_instance.io);
            self.stream = null;
        }
        self.connected = false;
    }

    fn requireStream(self: *MqttPlugin) !*std.Io.net.Stream {
        return &(self.stream orelse return error.NotConnected);
    }

    fn writeAll(self: *MqttPlugin, data: []const u8) !void {
        if (self.tls) |*tls| {
            try tls.client.writer.writeAll(data);
            return;
        }
        const s = try self.requireStream();
        var wbuf: [4096]u8 = undefined;
        var writer = s.writer(io_instance.io, &wbuf);
        try writer.interface.writeAll(data);
    }

    fn readExact(self: *MqttPlugin, buf: []u8) !void {
        if (self.tls) |*tls| {
            const n = try tls.client.reader.readSliceShort(buf);
            if (n < buf.len) return error.IncompleteConnack;
            return;
        }
        const s = try self.requireStream();
        sockread.readFull(s.*, buf) catch return error.IncompleteConnack;
    }

    fn encodeRemainingLength(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, len: usize) !void {
        var x = len;
        while (true) {
            var encoded: u8 = @intCast(x % 128);
            x /= 128;
            if (x > 0) encoded |= 0x80;
            try buf.append(allocator, encoded);
            if (x == 0) break;
        }
    }

    fn appendMqttString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
        try buf.append(allocator, @intCast(s.len >> 8));
        try buf.append(allocator, @intCast(s.len & 0xFF));
        try buf.appendSlice(allocator, s);
    }

    fn sendConnect(self: *MqttPlugin) !void {
        var vh: std.ArrayList(u8) = .empty;
        defer vh.deinit(self.allocator);

        // Protocol Name "MQTT" + level 4
        try appendMqttString(&vh, self.allocator, "MQTT");
        try vh.append(self.allocator, 0x04);

        var flags: u8 = 0x02; // Clean Session
        if (self.config.username != null) flags |= 0x80;
        if (self.config.password != null) flags |= 0x40;
        try vh.append(self.allocator, flags);
        try vh.append(self.allocator, @intCast(self.config.keep_alive >> 8));
        try vh.append(self.allocator, @intCast(self.config.keep_alive & 0xFF));

        try appendMqttString(&vh, self.allocator, self.config.client_id);
        if (self.config.username) |u| try appendMqttString(&vh, self.allocator, u);
        if (self.config.password) |p| try appendMqttString(&vh, self.allocator, p);

        var packet: std.ArrayList(u8) = .empty;
        defer packet.deinit(self.allocator);
        try packet.append(self.allocator, 0x10); // CONNECT
        try encodeRemainingLength(&packet, self.allocator, vh.items.len);
        try packet.appendSlice(self.allocator, vh.items);

        try self.writeAll(packet.items);
    }

    fn readConnack(self: *MqttPlugin) !void {
        var hdr: [4]u8 = undefined;
        try self.readExact(&hdr);
        if (hdr[0] != 0x20 or hdr[1] != 0x02) return error.UnexpectedPacket;
        if (hdr[3] != 0) return error.ConnackRefused;
    }

    /// PUBLISH QoS 0.
    pub fn publish(self: *MqttPlugin, topic: []const u8, payload: []const u8) !void {
        if (!self.connected) return error.NotConnected;

        var vh: std.ArrayList(u8) = .empty;
        defer vh.deinit(self.allocator);
        try appendMqttString(&vh, self.allocator, topic);
        try vh.appendSlice(self.allocator, payload);

        var packet: std.ArrayList(u8) = .empty;
        defer packet.deinit(self.allocator);
        try packet.append(self.allocator, 0x30); // PUBLISH QoS0
        try encodeRemainingLength(&packet, self.allocator, vh.items.len);
        try packet.appendSlice(self.allocator, vh.items);

        try self.writeAll(packet.items);
    }

    pub fn ping(self: *MqttPlugin) !void {
        if (!self.connected) return error.NotConnected;
        try self.writeAll(&[_]u8{ 0xC0, 0x00 }); // PINGREQ
    }
};

test "mqtt: encode remaining length" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try MqttPlugin.encodeRemainingLength(&buf, std.testing.allocator, 0);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x00}, buf.items);
    buf.clearRetainingCapacity();
    try MqttPlugin.encodeRemainingLength(&buf, std.testing.allocator, 127);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x7F}, buf.items);
    buf.clearRetainingCapacity();
    try MqttPlugin.encodeRemainingLength(&buf, std.testing.allocator, 128);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x01 }, buf.items);
}

test "mqtt: appendMqttString" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try MqttPlugin.appendMqttString(&buf, std.testing.allocator, "ab");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x02, 'a', 'b' }, buf.items);
}

test "mqtt: use_tls no longer returns TlsNotImplemented before TCP" {
    var plugin = MqttPlugin.init(std.testing.allocator, .{
        .broker_host = "127.0.0.1",
        .broker_port = 1,
        .client_id = "test",
        .use_tls = true,
    });
    defer plugin.deinit();
    const err = plugin.connect();
    try std.testing.expect(err != error.TlsNotImplemented);
}
