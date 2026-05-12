const std = @import("std");
const http = std.http;
const Router = @import("router.zig").Router;
const HttpMethod = @import("router.zig").HttpMethod;
const Context = @import("context.zig").Context;
const ThreadPool = @import("thread_pool.zig").ThreadPool;
const io_instance = @import("../io_instance.zig");
const getLog = @import("logger.zig").getLogger;

pub const ServerConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    thread_count: u32 = 0, // 0 = cpu_count * 2
    max_connections: usize = 10000,
    /// Maximum time (ms) to wait for a request head after accepting a connection.
    /// Connection is closed if the client sends no data within this window.
    read_timeout_ms: u64 = 30000,
    /// Maximum request body size in bytes (default: 10MB).
    max_body_size: usize = 10 * 1024 * 1024,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    router: *Router,
    config: ServerConfig,
    address: std.Io.net.IpAddress,
    pool: ?ThreadPool = null,

    pub fn init(allocator: std.mem.Allocator, router: *Router, config: ServerConfig) !Server {
        const address = try std.Io.net.IpAddress.parseIp4(config.host, config.port);
        return Server{
            .allocator = allocator,
            .router = router,
            .config = config,
            .address = address,
        };
    }

    pub fn start(self: *Server) !void {
        const thread_count: u32 = if (self.config.thread_count == 0)
            @intCast(try std.Thread.getCpuCount() * 2)
        else
            self.config.thread_count;

        var pool = try ThreadPool.init(self.allocator, thread_count, self.config.max_connections);
        self.pool = pool;

        var server = try self.address.listen(io_instance.io, .{
            .reuse_address = true,
        });
        defer server.deinit(io_instance.io);

        getLog().infoFmt("Server listening on {s}:{d} (threads: {d}, max_conn: {d})", .{
            self.config.host, self.config.port, thread_count, self.config.max_connections,
        });

        while (true) {
            const connection = try server.accept(io_instance.io);

            const task = try self.allocator.create(ConnectionTask);
            task.* = .{
                .server = self,
                .connection = connection,
            };
            pool.submitRaw(handleConnectionTask, task) catch |err| {
                std.debug.print("Failed to submit task: {}\n", .{err});
                self.allocator.destroy(task);
                connection.close(io_instance.io);
                // Return 503 if queue is full
                const response = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 19\r\n\r\nService Unavailable";
                var write_buf: [256]u8 = undefined;
                var writer = connection.writer(io_instance.io, &write_buf);
                _ = writer.interface.writeAll(response) catch {};
            };
        }
    }

    const ConnectionTask = struct {
        server: *Server,
        connection: std.Io.net.Stream,
    };

    fn handleConnectionTask(task_ptr: *anyopaque) void {
        const task: *ConnectionTask = @ptrCast(@alignCast(task_ptr));
        defer task.connection.close(io_instance.io);
        defer task.server.allocator.destroy(task);

        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var stream_reader = task.connection.reader(io_instance.io, &read_buffer);
        var stream_writer = task.connection.writer(io_instance.io, &write_buffer);
        var http_server = http.Server.init(&stream_reader.interface, &stream_writer.interface);

        var request = http_server.receiveHead() catch |err| {
            std.debug.print("Error receiving head: {}\n", .{err});
            return;
        };

        var ctx = Context.init(&request, task.server.allocator);
        defer ctx.deinit();

        const target = request.head.target;
        const path = if (std.mem.indexOfScalar(u8, target, '?')) |q_pos|
            target[0..q_pos]
        else
            target;

        const method = HttpMethod.fromString(@tagName(request.head.method)) orelse .GET;

        task.server.router.execute(path, method, &ctx) catch |err| {
            std.debug.print("Handler error: {}\n", .{err});
            ctx.res_status = .internal_server_error;
            ctx.renderText("Internal Server Error") catch {};
        };
    }
};
