const std = @import("std");
const zfinal = @import("../core/zfinal.zig");
const Plugin = @import("plugin.zig").Plugin;

/// MQTT Client Configuration
pub const MqttConfig = struct {
    broker_host: []const u8,
    broker_port: u16 = 1883,
    client_id: []const u8,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    keep_alive: u16 = 60,
};

/// MQTT Plugin Implementation
pub const MqttPlugin = struct {
    allocator: std.mem.Allocator,
    config: MqttConfig,
    socket: ?std.net.Stream = null,
    running: bool = false,
    read_thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, config: MqttConfig) MqttPlugin {
        return MqttPlugin{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *MqttPlugin) void {
        self.stop() catch {};
    }

    /// Implement Plugin interface
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

    fn start(ctx: *anyopaque) !void {
        const self: *MqttPlugin = @ptrCast(@alignCast(ctx));
        std.debug.print("Starting MQTT Plugin connecting to {s}:{d}...\n", .{ self.config.broker_host, self.config.broker_port });

        // Connect to broker
        self.socket = try std.net.tcpConnectToHost(self.allocator, self.config.broker_host, self.config.broker_port);
        self.running = true;

        // Send CONNECT packet
        try self.sendConnect();

        // Start read loop in a separate thread
        self.read_thread = try std.Thread.spawn(.{}, readLoop, .{self});

        std.debug.print("MQTT Plugin started.\n", .{});
    }

    fn stop(ctx: *anyopaque) !void {
        const self: *MqttPlugin = @ptrCast(@alignCast(ctx));
        if (!self.running) return;

        self.running = false;
        if (self.socket) |sock| {
            sock.close();
            self.socket = null;
        }

        if (self.read_thread) |thread| {
            thread.join();
            self.read_thread = null;
        }
        std.debug.print("MQTT Plugin stopped.\n", .{});
    }

    fn readLoop(self: *MqttPlugin) void {
        var buffer: [4096]u8 = undefined;
        while (self.running) {
            if (self.socket) |sock| {
                const bytes_read = sock.read(&buffer) catch |err| {
                    std.debug.print("MQTT read error: {}\n", .{err});
                    self.running = false;
                    break;
                };

                if (bytes_read == 0) {
                    std.debug.print("MQTT connection closed by broker.\n", .{});
                    self.running = false;
                    break;
                }

                // Handle incoming packets (simplified)
                self.handlePacket(buffer[0..bytes_read]);
            } else {
                break;
            }
        }
    }

    fn handlePacket(self: *MqttPlugin, data: []const u8) void {
        _ = self;
        if (data.len < 2) return;
        const packet_type = data[0] >> 4;

        switch (packet_type) {
            2 => std.debug.print("MQTT: CONNACK received\n", .{}),
            3 => std.debug.print("MQTT: PUBLISH received\n", .{}),
            else => std.debug.print("MQTT: Received packet type {}\n", .{packet_type}),
        }
    }

    fn sendConnect(self: *MqttPlugin) !void {
        if (self.socket) |sock| {
            // Minimal CONNECT packet construction
            // Fixed Header: Type 1 (CONNECT), Remaining Length
            // Variable Header: Protocol Name, Level, Connect Flags, Keep Alive
            // Payload: Client ID

            var packet = std.ArrayList(u8).init(self.allocator);
            defer packet.deinit();

            // Variable Header
            // Protocol Name "MQTT"
            try packet.appendSlice(&[_]u8{ 0x00, 0x04, 'M', 'Q', 'T', 'T' });
            // Protocol Level 4 (3.1.1)
            try packet.append(0x04);
            // Connect Flags (Clean Session)
            try packet.append(0x02);
            // Keep Alive
            try packet.appendSlice(&[_]u8{ @intCast(self.config.keep_alive >> 8), @intCast(self.config.keep_alive & 0xFF) });

            // Payload
            // Client ID
            try packet.appendSlice(&[_]u8{ @intCast(self.config.client_id.len >> 8), @intCast(self.config.client_id.len & 0xFF) });
            try packet.appendSlice(self.config.client_id);

            // Fixed Header
            var fixed_header = std.ArrayList(u8).init(self.allocator);
            defer fixed_header.deinit();
            try fixed_header.append(0x10); // CONNECT type

            // Remaining Length (simplified, assuming < 128 bytes for now)
            try fixed_header.append(@intCast(packet.items.len));

            try sock.writeAll(fixed_header.items);
            try sock.writeAll(packet.items);
        }
    }

    pub fn publish(self: *MqttPlugin, topic: []const u8, payload: []const u8) !void {
        if (self.socket) |sock| {
            // Minimal PUBLISH packet
            var packet = std.ArrayList(u8).init(self.allocator);
            defer packet.deinit();

            // Variable Header: Topic Name
            try packet.appendSlice(&[_]u8{ @intCast(topic.len >> 8), @intCast(topic.len & 0xFF) });
            try packet.appendSlice(topic);

            // Payload
            try packet.appendSlice(payload);

            // Fixed Header
            var fixed_header = std.ArrayList(u8).init(self.allocator);
            defer fixed_header.deinit();
            try fixed_header.append(0x30); // PUBLISH type (QoS 0)

            // Remaining Length (simplified)
            try fixed_header.append(@intCast(packet.items.len));

            try sock.writeAll(fixed_header.items);
            try sock.writeAll(packet.items);
        }
    }
};
