const std = @import("std");
const io_instance = @import("../io_instance.zig");
const Plugin = @import("plugin.zig").Plugin;

pub const NodeInfo = struct {
    id: []const u8,
    address: std.Io.net.IpAddress,
};

pub const P2pPlugin = struct {
    allocator: std.mem.Allocator,
    port: u16,
    discovery_port: u16 = 9999,
    nodes: std.ArrayList(NodeInfo),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    server_thread: ?std.Thread = null,
    discovery_thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, port: u16) P2pPlugin {
        return P2pPlugin{
            .allocator = allocator,
            .port = port,
            .nodes = std.ArrayList(NodeInfo).empty,
        };
    }

    pub fn deinit(self: *P2pPlugin) void {
        self.stop() catch {};
        self.nodes.deinit();
    }

    pub fn plugin(self: *P2pPlugin) Plugin {
        return Plugin{
            .name = "P2P",
            .vtable = &.{ .start = start, .stop = stop },
            .context = self,
        };
    }

    fn start(ctx: *anyopaque) !void {
        const self: *P2pPlugin = @ptrCast(@alignCast(ctx));
        self.running.store(true, .monotonic);

        self.server_thread = try std.Thread.spawn(.{}, serverLoop, .{self});
        self.discovery_thread = try std.Thread.spawn(.{}, discoveryLoop, .{self});
    }

    fn stop(ctx: *anyopaque) !void {
        const self: *P2pPlugin = @ptrCast(@alignCast(ctx));
        if (!self.running.swap(false, .monotonic)) return;

        // Join threads — serverLoop exits when running becomes false (may block on accept,
        // in production a shutdown socket or timeout should be used).
        if (self.server_thread) |thread| {
            thread.join();
            self.server_thread = null;
        }
        if (self.discovery_thread) |thread| {
            thread.join();
            self.discovery_thread = null;
        }
    }

    fn serverLoop(self: *P2pPlugin) void {
        const address = std.Io.net.IpAddress.parseIp4("0.0.0.0", self.port) catch return;
        var server = address.listen(io_instance.io, .{ .reuse_address = true }) catch return;
        defer server.deinit(io_instance.io);

        while (self.running.load(.monotonic)) {
            const conn = server.accept(io_instance.io) catch {
                if (!self.running.load(.monotonic)) break;
                continue;
            };
            defer conn.close(io_instance.io);
        }
    }

    fn discoveryLoop(self: *P2pPlugin) void {
        while (self.running.load(.monotonic)) {
            std.Io.sleep(io_instance.io, std.Io.Duration.fromSeconds(1), .awake) catch {};
        }
    }

    pub fn broadcast(self: *P2pPlugin, message: []const u8) !void {
        _ = self;
        _ = message;
    }
};
