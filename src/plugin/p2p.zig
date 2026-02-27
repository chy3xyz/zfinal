const std = @import("std");
const zfinal = @import("../core/zfinal.zig");
const Plugin = @import("plugin.zig").Plugin;

/// P2P Node Info
pub const NodeInfo = struct {
    id: []const u8,
    address: std.net.Address,
};

/// P2P Plugin Implementation
pub const P2pPlugin = struct {
    allocator: std.mem.Allocator,
    port: u16,
    discovery_port: u16 = 9999,
    nodes: std.ArrayList(NodeInfo),
    running: bool = false,
    server_thread: ?std.Thread = null,
    discovery_thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, port: u16) P2pPlugin {
        return P2pPlugin{
            .allocator = allocator,
            .port = port,
            .nodes = std.ArrayList(NodeInfo).init(allocator),
        };
    }

    pub fn deinit(self: *P2pPlugin) void {
        self.stop() catch {};
        self.nodes.deinit();
    }

    /// Implement Plugin interface
    pub fn plugin(self: *P2pPlugin) Plugin {
        return Plugin{
            .name = "P2P",
            .vtable = &.{
                .start = start,
                .stop = stop,
            },
            .context = self,
        };
    }

    fn start(ctx: *anyopaque) !void {
        const self: *P2pPlugin = @ptrCast(@alignCast(ctx));
        std.debug.print("Starting P2P Plugin on port {d}...\n", .{self.port});
        self.running = true;

        // Start TCP Server
        self.server_thread = try std.Thread.spawn(.{}, serverLoop, .{self});

        // Start UDP Discovery
        self.discovery_thread = try std.Thread.spawn(.{}, discoveryLoop, .{self});

        std.debug.print("P2P Plugin started.\n", .{});
    }

    fn stop(ctx: *anyopaque) !void {
        const self: *P2pPlugin = @ptrCast(@alignCast(ctx));
        if (!self.running) return;
        self.running = false;

        // Join threads (simplified, needs proper cancellation)
        if (self.server_thread) |thread| {
            thread.detach(); // Detach for now as we don't have clean socket shutdown in this simple example
            self.server_thread = null;
        }
        if (self.discovery_thread) |thread| {
            thread.detach();
            self.discovery_thread = null;
        }
        std.debug.print("P2P Plugin stopped.\n", .{});
    }

    fn serverLoop(self: *P2pPlugin) void {
        const address = std.net.Address.parseIp4("0.0.0.0", self.port) catch return;
        var server = address.listen(.{ .reuse_address = true }) catch return;
        defer server.deinit();

        while (self.running) {
            const conn = server.accept() catch |err| {
                std.debug.print("P2P accept error: {}\n", .{err});
                continue;
            };

            // Handle connection in a new thread or async task
            // For now, just print and close
            std.debug.print("P2P: New connection from {}\n", .{conn.address});
            conn.stream.close();
        }
    }

    fn discoveryLoop(self: *P2pPlugin) void {
        const address = std.net.Address.parseIp4("0.0.0.0", self.discovery_port) catch return;
        const socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP) catch return;
        defer std.posix.close(socket);

        // Bind socket
        std.posix.bind(socket, &address.any, address.getOsSockLen()) catch return;

        var buffer: [1024]u8 = undefined;
        while (self.running) {
            var src_addr: std.posix.sockaddr = undefined;
            var src_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

            const len = std.posix.recvfrom(socket, &buffer, 0, &src_addr, &src_len) catch continue;

            if (len > 0) {
                const msg = buffer[0..len];
                std.debug.print("P2P Discovery: Received {s}\n", .{msg});
                // Parse message and add node to list
            }
        }
    }

    pub fn broadcast(self: *P2pPlugin, message: []const u8) !void {
        // Send UDP broadcast
        const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
        defer std.posix.close(socket);

        const broadcast_addr = try std.net.Address.parseIp4("127.0.0.1", self.discovery_port);

        // Enable broadcast
        const one: i32 = 1;
        try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.BROADCAST, std.mem.asBytes(&one));

        _ = try std.posix.sendto(socket, message, 0, &broadcast_addr.any, broadcast_addr.getOsSockLen());
    }
};
