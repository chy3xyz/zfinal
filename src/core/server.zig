const std = @import("std");
const http = std.http;
const Router = @import("router.zig").Router;
const HttpMethod = @import("router.zig").HttpMethod;
const Context = @import("context.zig").Context;
const io_instance = @import("../io_instance.zig");

pub const Server = struct {
    allocator: std.mem.Allocator,
    router: *Router,
    address: std.Io.net.IpAddress,

    pub fn init(allocator: std.mem.Allocator, router: *Router, port: u16) !Server {
        const address = try std.Io.net.IpAddress.parseIp("127.0.0.1", port);
        return Server{
            .allocator = allocator,
            .router = router,
            .address = address,
        };
    }

    pub fn start(self: *Server) !void {
        var server = try self.address.listen(io_instance.io, .{
            .reuse_address = true,
        });
        defer server.deinit();

        std.debug.print("Server listening on {}\n", .{self.address});

        while (true) {
            const connection = try server.accept(io_instance.io);
            // Spawn a thread or handle in a pool in a real app.
            // For now, handle sequentially or in a detached thread.
            // To keep it simple and safe for now, we'll run in a thread.
            const thread = try std.Thread.spawn(.{}, handleConnection, .{ self, connection });
            thread.detach();
        }
    }

    fn handleConnection(self: *Server, connection: std.Io.net.Server.Connection) void {
        defer connection.stream.close(io_instance.io);

        var read_buffer: [4096]u8 = undefined;
        var http_server = http.Server.init(connection, &read_buffer);

        var request = http_server.receiveHead() catch |err| {
            std.debug.print("Error receiving head: {}\n", .{err});
            return;
        };

        var ctx = Context.init(&request, self.allocator);
        defer ctx.deinit();

        const target = request.head.target;
        // Strip query string from path for routing
        const path = if (std.mem.indexOfScalar(u8, target, '?')) |q_pos|
            target[0..q_pos]
        else
            target;

        // Get HTTP method
        const method = HttpMethod.fromString(@tagName(request.head.method)) orelse .GET;

        // Execute with interceptor chain
        self.router.execute(path, method, &ctx) catch |err| {
            std.debug.print("Handler error: {}\n", .{err});
            ctx.res_status = .internal_server_error;
            ctx.renderText("Internal Server Error") catch {};
        };
    }
};
