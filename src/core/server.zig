const std = @import("std");
const http = std.http;
const Router = @import("router.zig").Router;
const HttpMethod = @import("router.zig").HttpMethod;
const Context = @import("context.zig").Context;
const getLog = @import("logger.zig").getLogger;
const shutdown = @import("shutdown.zig");

pub const ServerConfig = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    thread_count: u32 = 0,
    max_connections: usize = 10000,
    max_requests_per_conn: usize = 100,
    max_body_size: usize = 10 * 1024 * 1024,
};

/// Error set for server operations. Wrapped to fit Group.async std.Io.Cancelable!void constraint.
pub const ServerError = error{
    ListenFailed,
    AcceptFailed,
    AddressInvalid,
};

/// Cross-fiber error container. Stores the first fatal error as a message.
const ErrorHandle = struct {
    err: bool = false,

    fn set(self: *ErrorHandle) void {
        self.err = true;
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    router: *Router,
    config: ServerConfig,
    active_conns: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    err_handle: ErrorHandle = .{},

    pub fn init(allocator: std.mem.Allocator, router: *Router, config: ServerConfig) !Server {
        return .{ .allocator = allocator, .router = router, .config = config };
    }

    /// Start the server. Blocks until shutdown or fatal error.
    pub fn start(self: *Server) !void {
        const tc: u32 = if (self.config.thread_count == 0)
            @intCast(try std.Thread.getCpuCount())
        else
            self.config.thread_count;

        getLog().infoFmt("Server starting on http://{s}:{d} (threads={d})", .{ self.config.host, self.config.port, tc });

        var threaded = std.Io.Threaded.init(self.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var group = std.Io.Group.init;
        defer { _ = group.await(io) catch {}; }

        const addr = try std.Io.net.IpAddress.parseIp4(self.config.host, self.config.port);

        // Spawn accept loop via Group.async. The wrapper satisfies std.Io.Cancelable!void.
        // Real errors are caught and stored in self.err_handle.
        group.async(io, acceptLoop, .{ io, self, addr, &group });

        // Block until all fibers complete (server shutdown or fatal error)
        _ = group.await(io) catch {};

        // Check for fatal errors captured by the wrapper
        if (self.err_handle.err) return error.ServerFatalError;
    }
};

// ============================================================
// Inner business logic — returns full ServerError!void
// ============================================================

fn acceptLoopImpl(io: std.Io, server: *Server, addr: std.Io.net.IpAddress, group: *std.Io.Group) !void {
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    getLog().infoFmt("Server listening on http://{s}:{d}", .{ server.config.host, server.config.port });

    var backoff: u64 = 1;
    while (!shutdown.isShuttingDown()) {
        const conn = listener.accept(io) catch |err| {
            getLog().warnFmt("Accept error: {} — retrying in {d}ms", .{ err, backoff });
            io.sleep(std.Io.Duration.fromMilliseconds(@intCast(backoff)), .awake) catch {};
            backoff = @min(backoff * 2, 1000);
            continue;
        };
        backoff = 1;

        const current = server.active_conns.load(.monotonic);
        if (current >= server.config.max_connections) {
            const body = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 19\r\nConnection: close\r\n\r\nService Unavailable";
            var wbuf: [256]u8 = undefined;
            var writer = conn.writer(io, &wbuf);
            _ = writer.interface.writeAll(body) catch {};
            conn.close(io);
            continue;
        }

        group.async(io, handleConn, .{ io, conn, server });
    }
    // Graceful shutdown: cancel pending fibers, drain connections
    getLog().info("Shutting down server...", .{});
    group.cancel(io);
}

/// Handler fiber — manages keep-alive request loop for one connection.
fn handleConn(io: std.Io, conn: std.Io.net.Stream, server: *Server) std.Io.Cancelable!void {
    defer conn.close(io);
    defer _ = server.active_conns.fetchSub(1, .monotonic);
    _ = server.active_conns.fetchAdd(1, .monotonic);

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var reader = conn.reader(io, &read_buf);
    var writer = conn.writer(io, &write_buf);
    var http_srv = http.Server.init(&reader.interface, &writer.interface);
    var req_count: usize = 0;

    while (req_count < server.config.max_requests_per_conn) : (req_count += 1) {
        var request = http_srv.receiveHead() catch break;
        dispatch(&request, server) catch break;
        if (request.head.version != .@"HTTP/1.1") break;
        if (!request.head.keep_alive) break;
    }
}

fn dispatch(request: *http.Server.Request, server: *Server) !void {
    const target = request.head.target;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
    const method = HttpMethod.fromString(@tagName(request.head.method)) orelse .GET;

    var ctx = Context.init(request, server.allocator);
    ctx.max_body_size = server.config.max_body_size;
    defer ctx.deinit();

    server.router.execute(path, method, &ctx) catch |err| {
        getLog().errFmt("Handler error: {} for {s} {s}", .{ err, @tagName(request.head.method), target });
        ctx.res_status = .internal_server_error;
        ctx.renderText("Internal Server Error") catch {};
    };
}

// ============================================================
// Group.async wrappers — constrain return type to std.Io.Cancelable!void
// ============================================================

fn acceptLoop(io: std.Io, server: *Server, addr: std.Io.net.IpAddress, group: *std.Io.Group) std.Io.Cancelable!void {
    acceptLoopImpl(io, server, addr, group) catch |e| {
        getLog().errFmt("Server fatal error: {}", .{e});
        server.err_handle.set();
        group.cancel(io);
    };
}
