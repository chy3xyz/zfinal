const std = @import("std");
const http = std.http;
const Router = @import("router.zig").Router;
const HttpMethod = @import("router.zig").HttpMethod;
const Context = @import("context.zig").Context;

/// Async HTTP Server configuration
pub const AsyncServerConfig = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    /// 0 = automatically use CPU core count
    thread_count: u32 = 0,
    /// read buffer size per connection
    read_buf_size: usize = 4096,
    /// max keep-alive requests per connection
    max_requests_per_conn: usize = 100,
};

/// Async HTTP Server using fiber-based concurrency
/// Uses Io.Threaded runtime for efficient async I/O with kqueue (macOS) / io_uring (Linux)
pub const AsyncServer = struct {
    allocator: std.mem.Allocator,
    router: *Router,
    config: AsyncServerConfig,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, router: *Router, config: AsyncServerConfig) !Self {
        return Self{
            .allocator = allocator,
            .router = router,
            .config = config,
        };
    }

    /// Start the async server using Io.Threaded runtime
    pub fn start(self: *Self) !void {
        const thread_count: u32 = if (self.config.thread_count == 0)
            @intCast(try std.Thread.getCpuCount())
        else
            self.config.thread_count;

        std.debug.print("Starting AsyncServer with {d} threads on http://{s}:{d}\n", .{
            thread_count, self.config.host, self.config.port,
        });

        var threaded = try std.Io.Threaded.init(self.allocator, .{
            .thread_count = thread_count,
        });
        defer threaded.deinit();

        const io = threaded.io();

        // Create a group to manage all connection fibers
        var conn_group = std.Io.Group.init(io);
        defer conn_group.await();

        const address = try std.Io.net.IpAddress.parseIp(self.config.host, self.config.port);

        try io.run(serverLoop, .{ io, self, address, &conn_group });
    }
};

/// Main server loop fiber - accepts connections and spawns handler fibers
fn serverLoop(io: *std.Io, server: *AsyncServer, address: std.Io.net.IpAddress, conn_group: *std.Io.Group) !void {
    var listener = try address.listen(io, .{
        .reuse_address = true,
        .reuse_port = true,
    });
    defer listener.deinit();

    std.debug.print("AsyncServer listening on http://{s}:{d}\n", .{ server.config.host, server.config.port });

    while (true) {
        // Accept connection - yields in fiber, doesn't block OS thread
        const conn = try listener.accept();
        std.debug.print("[AsyncServer] Connection from {}\n", .{conn.address});

        // Spawn connection handler fiber managed by Group (no memory leak)
        conn_group.async(handleConnectionFiber, .{ io, conn, server }) catch |err| {
            std.debug.print("[AsyncServer] Failed to spawn connection fiber: {}\n", .{err});
            conn.stream.close();
        };
    }
}

/// Connection handler fiber - handles all requests on a single connection
fn handleConnectionFiber(io: *std.Io, conn: std.Io.net.Server.Connection, server: *AsyncServer) void {
    _ = io; // io reserved for fiber context
    defer conn.stream.close();

    // Stack-allocated buffer per fiber (no heap allocation per request)
    var read_buffer: [4096]u8 = undefined;
    var http_server = http.Server.init(conn, &read_buffer);
    var req_count: usize = 0;

    while (req_count < server.config.max_requests_per_conn) : (req_count += 1) {
        // Receive HTTP request head (headers)
        const request = http_server.receiveHead() catch |err| {
            std.debug.print("[AsyncServer] Receive error: {} on connection {}\n", .{ err, conn.address });
            break;
        };

        std.debug.print("[AsyncServer] {} {} from {}\n", .{
            @tagName(request.head.method), request.head.target, conn.address,
        });

        // Create context and dispatch to router
        dispatch(request, server) catch |err| {
            std.debug.print("[AsyncServer] Dispatch error: {} for {} {}\n", .{
                err, @tagName(request.head.method), request.head.target,
            });
            break;
        };

        // Check if connection should be kept alive
        if (request.head.version != .@"1.1") break;
        if (request.shouldKeepAlive() == false) break;
    }

    std.debug.print("[AsyncServer] Connection closed ({d} requests from {})\n", .{ req_count, conn.address });
}

/// Dispatch request to router
fn dispatch(request: http.Server.Request, server: *AsyncServer) !void {
    const target = request.head.target;

    // Strip query string from path for routing
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q_pos|
        target[0..q_pos]
    else
        target;

    // Get HTTP method
    const method = HttpMethod.fromString(@tagName(request.head.method)) orelse .GET;

    // Find matching route
    const route = server.router.match(path, method) orelse {
        request.respond("Not Found", .{
            .status = .not_found,
            .content_type = .plain,
        }) catch {};
        return;
    };

    // Create context
    var ctx = Context.init(&request, server.allocator);
    defer ctx.deinit();

    // Extract path parameters
    if (route.param_names.len > 0) {
        ctx.path_params = try route.extractParams(path, server.allocator);
    }

    // Execute interceptors and handler
    try server.router.execute(path, method, &ctx);
}