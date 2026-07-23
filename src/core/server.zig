const std = @import("std");
const http = std.http;
const Router = @import("router.zig").Router;
const HttpMethod = @import("router.zig").HttpMethod;
const Context = @import("context.zig").Context;
const Metrics = @import("metrics.zig").Metrics;
const getLog = @import("logger.zig").getLogger;
const shutdown = @import("shutdown.zig");
const io_instance = @import("../io_instance.zig");

pub const ServerConfig = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    thread_count: u32 = 0,
    max_connections: usize = 10000,
    max_requests_per_conn: usize = 100,
    max_body_size: usize = 10 * 1024 * 1024,
    /// Max time to wait for in-flight connections after SIGTERM/SIGINT (ms).
    /// Prevents hang forever when a client never closes. Default 30s.
    drain_timeout_ms: u64 = 30_000,
    /// Per-connection idle timeout (ms) **between** requests (waiting on
    /// `receiveHead`). The idle watchdog does **not** run during `dispatch`
    /// — handler duration is bounded by `Context` deadline / DB pool
    /// `acquire_timeout` instead. Closing the socket mid-handler caused
    /// mass `WriteFailed` under concurrency (idle == acquire == 30s).
    /// 0 disables. Default 30s. Still pair with reverse-proxy timeouts.
    request_timeout_ms: u64 = 30_000,
    /// Per `net_read` deadline (ms) via `Io.operateTimeout` for receiveHead/body.
    /// 0 disables (rely on idle watchdog only). Default matches request_timeout_ms.
    read_timeout_ms: u64 = 30_000,
    /// Per-response write deadline (ms), wall-clock from the first `drain`
    /// of each request. Zig 0.17 removed `Operation.net_write`, so this is
    /// enforced in user space rather than via `operateTimeout`. 0 disables.
    /// Default matches request_timeout_ms. Prefer also terminating TLS/proxy
    /// write timeouts at the reverse proxy.
    write_timeout_ms: u64 = 30_000,
    /// When true (default), force one-request-per-connection to avoid
    /// Zig `http.Server` keep-alive / discardBody bugs (ziglang/zig#25017;
    /// still asserts on 0.17.0-dev.1422). Production: keep true and put client
    /// keep-alive on nginx/Caddy — `doc/reverse_proxy.md`.
    /// Set false only after full body-drain coverage + upstream fix + soak tests.
    force_connection_close: bool = true,
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
    /// Optional shared metrics; when set, dispatch auto-records status classes.
    metrics: ?*Metrics = null,
    active_conns: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    err_handle: ErrorHandle = .{},
    /// Listener socket, stored so a shutdown watchdog can close it to unblock accept().
    listener: std.Io.net.Server = undefined,
    listener_closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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

        var threaded = std.Io.Threaded.init(self.allocator, .{
            .async_limit = if (self.config.thread_count == 0) null else std.Io.Limit.limited(self.config.thread_count),
        });
        defer threaded.deinit();
        const io = threaded.io();

        var group = std.Io.Group.init;

        const addr = try std.Io.net.IpAddress.parseIp4(self.config.host, self.config.port);

        // Spawn accept loop via Group.async. The wrapper satisfies std.Io.Cancelable!void.
        // Real errors are caught and stored in self.err_handle.
        group.async(io, acceptLoop, .{ io, self, addr, &group });

        // Block until all fibers complete (server shutdown or fatal error).
        // threaded.deinit() at defer above handles I/O cleanup.
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
    server.listener = listener;
    defer {
        if (!server.listener_closed.load(.monotonic)) {
            listener.deinit(io);
        }
    }

    getLog().infoFmt("Server listening on http://{s}:{d}", .{ server.config.host, server.config.port });

    // Watchdog: once a shutdown signal is received, close the listener socket
    // so the blocking accept() returns immediately with SocketNotListening.
    group.async(io, shutdownWatcher, .{ io, server });

    var backoff: u64 = 1;
    while (!shutdown.isShuttingDown()) {
        const conn = listener.accept(io) catch |err| {
            if (shutdown.isShuttingDown()) break;
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
            _ = writer.interface.writeAll(body) catch |err| {
                getLog().debugFmt("Failed to write 503 response: {t}", .{err});
            };
            conn.close(io);
            continue;
        }

        group.async(io, handleConn, .{ io, conn, server });
    }
    // Graceful shutdown: drain pending connections with a hard deadline.
    getLog().info("Shutting down server...", .{});
    const drain_deadline_ms = server.config.drain_timeout_ms;
    var waited_ms: u64 = 0;
    while (server.active_conns.load(.monotonic) > 0) {
        if (waited_ms >= drain_deadline_ms) {
            getLog().warnFmt(
                "Drain timeout ({d}ms) reached with {d} active connection(s); exiting",
                .{ drain_deadline_ms, server.active_conns.load(.monotonic) },
            );
            break;
        }
        io.sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch break;
        waited_ms += 100;
    }
    if (server.active_conns.load(.monotonic) == 0) {
        getLog().info("All connections drained.", .{});
    }
}

/// Handler fiber — manages keep-alive request loop for one connection.
fn handleConn(io: std.Io, conn: std.Io.net.Stream, server: *Server) std.Io.Cancelable!void {
    defer _ = server.active_conns.fetchSub(1, .monotonic);
    _ = server.active_conns.fetchAdd(1, .monotonic);
    if (server.metrics) |m| m.recordConnection();

    var conn_closed = std.atomic.Value(bool).init(false);
    defer {
        if (!conn_closed.swap(true, .monotonic)) conn.close(io);
    }

    var last_activity_ms = std.atomic.Value(u64).init(monoMs(io));
    // True while `dispatch` runs — idle watchdog must not close the socket
    // mid-handler (that produced WriteFailed storms under load).
    var in_dispatch = std.atomic.Value(bool).init(false);
    var finished = std.atomic.Value(bool).init(false);
    defer finished.store(true, .release);

    var idle_group = std.Io.Group.init;
    if (server.config.request_timeout_ms > 0) {
        idle_group.async(io, idleWatchdog, .{
            io,
            conn,
            &last_activity_ms,
            &in_dispatch,
            &finished,
            &conn_closed,
            server.config.request_timeout_ms,
        });
    }
    defer {
        finished.store(true, .release);
        _ = idle_group.await(io) catch {};
    }

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var reader = TimedReader.init(conn, io, &read_buf, server.config.read_timeout_ms);
    var writer = TimedWriter.init(conn, io, &write_buf, server.config.write_timeout_ms);
    var http_srv = http.Server.init(&reader.interface, &writer.interface);
    var req_count: usize = 0;

    while (req_count < server.config.max_requests_per_conn) : (req_count += 1) {
        if (conn_closed.load(.monotonic)) break;
        last_activity_ms.store(monoMs(io), .monotonic);
        var request = http_srv.receiveHead() catch break;
        last_activity_ms.store(monoMs(io), .monotonic);
        writer.resetWriteDeadline();
        in_dispatch.store(true, .release);
        const dispatch_err = dispatch(&request, server);
        in_dispatch.store(false, .release);
        last_activity_ms.store(monoMs(io), .monotonic);
        dispatch_err catch break;
        if (request.head.version != .@"HTTP/1.1") break;
        if (!request.head.keep_alive) break;
    }
}

/// Stream reader that applies `Io.operateTimeout` on each `net_read`.
const TimedReader = struct {
    io: std.Io,
    interface: std.Io.Reader,
    stream: std.Io.net.Stream,
    timeout_ms: u64,
    err: ?anyerror = null,

    const max_iovecs_len = 8;

    fn init(stream: std.Io.net.Stream, io: std.Io, buffer: []u8, timeout_ms: u64) TimedReader {
        return .{
            .io = io,
            .interface = .{
                .vtable = &.{
                    .stream = streamImpl,
                    .readVec = readVec,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .stream = stream,
            .timeout_ms = timeout_ms,
        };
    }

    fn streamImpl(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn readVec(io_r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const r: *TimedReader = @alignCast(@fieldParentPtr("interface", io_r));
        var iovecs_buffer: [max_iovecs_len][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs_buffer, data);
        const dest = iovecs_buffer[0..dest_n];
        std.debug.assert(dest[0].len > 0);

        const timeout: std.Io.Timeout = if (r.timeout_ms == 0)
            .none
        else
            .{ .duration = .{
                .raw = .fromMilliseconds(@intCast(r.timeout_ms)),
                .clock = .awake,
            } };

        const n = (r.io.operateTimeout(.{
            .net_read = .{
                .socket_handle = r.stream.socket.handle,
                .data = dest,
            },
        }, timeout) catch |err| {
            r.err = err;
            return error.ReadFailed;
        }).net_read catch |err| {
            r.err = err;
            return error.ReadFailed;
        };

        if (n == 0) return error.EndOfStream;
        if (n > data_size) {
            r.interface.end += n - data_size;
            return data_size;
        }
        return n;
    }
};

/// Stream writer backed by `Io.vtable.netWrite`.
/// Enforces `write_timeout_ms` as a wall-clock deadline from the first
/// `drain` of each response (call `resetWriteDeadline` per request).
/// Zig 0.17 removed `Operation.net_write`, so `operateTimeout` cannot
/// apply per-syscall write deadlines.
const TimedWriter = struct {
    io: std.Io,
    interface: std.Io.Writer,
    stream: std.Io.net.Stream,
    timeout_ms: u64,
    /// Absolute mono deadline (ms); 0 means "not started for this response".
    write_deadline_ms: u64 = 0,
    err: ?anyerror = null,

    fn init(stream: std.Io.net.Stream, io: std.Io, buffer: []u8, timeout_ms: u64) TimedWriter {
        return .{
            .io = io,
            .interface = .{
                .vtable = &.{
                    .drain = drain,
                },
                .buffer = buffer,
            },
            .stream = stream,
            .timeout_ms = timeout_ms,
        };
    }

    fn resetWriteDeadline(self: *TimedWriter) void {
        self.write_deadline_ms = 0;
    }

    fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const w: *TimedWriter = @alignCast(@fieldParentPtr("interface", io_w));
        if (w.timeout_ms > 0) {
            const now = monoMs(w.io);
            if (w.write_deadline_ms == 0) {
                w.write_deadline_ms = now +% w.timeout_ms;
            } else if (now >= w.write_deadline_ms) {
                w.err = error.WriteTimedOut;
                return error.WriteFailed;
            }
        }
        const n = w.io.vtable.netWrite(w.io.userdata, w.stream.socket.handle, io_w.buffered(), data, splat) catch |err| {
            w.err = err;
            return error.WriteFailed;
        };
        return io_w.consume(n);
    }
};

fn idleWatchdog(
    io: std.Io,
    conn: std.Io.net.Stream,
    last_activity_ms: *std.atomic.Value(u64),
    in_dispatch: *std.atomic.Value(bool),
    finished: *std.atomic.Value(bool),
    conn_closed: *std.atomic.Value(bool),
    timeout_ms: u64,
) std.Io.Cancelable!void {
    while (!finished.load(.acquire)) {
        io.sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch break;
        if (finished.load(.acquire)) break;
        // Handler in progress: do not treat slow DB/business work as idle.
        if (in_dispatch.load(.acquire)) continue;
        const now = monoMs(io);
        const last = last_activity_ms.load(.monotonic);
        if (now > last and (now - last) >= timeout_ms) {
            getLog().warnFmt("Request idle timeout ({d}ms); closing connection", .{timeout_ms});
            if (!conn_closed.swap(true, .monotonic)) {
                conn.close(io);
            }
            break;
        }
    }
}

fn monoMs(io: std.Io) u64 {
    const ts = std.Io.Timestamp.now(io, .awake);
    return @intCast(@max(ts.toMilliseconds(), 0));
}

fn dispatch(request: *http.Server.Request, server: *Server) !void {
    const target = request.head.target;
    const safe_target = if (target.len > 4096) target[0..4096] else target;
    const path = if (std.mem.indexOfScalar(u8, safe_target, '?')) |q| safe_target[0..q] else safe_target;
    const method = HttpMethod.fromString(@tagName(request.head.method)) orelse .GET;
    const start_ms: i64 = std.Io.Timestamp.now(io_instance.io, .awake).toMilliseconds();

    var ctx = Context.init(request, server.allocator);
    ctx.max_body_size = server.config.max_body_size;
    // Set the per-request deadline up front. Handlers / dispatch loops
    // can check `ctx.isExpired()` to bail out of long work.
    if (server.config.request_timeout_ms > 0) {
        ctx.setTimeoutMs(server.config.request_timeout_ms);
    }
    defer ctx.deinit();

    // Check deadline once before invoking handler — fast path for
    // already-expired requests (e.g. clock skew, very fast 504).
    if (ctx.isExpired()) {
        getLog().warnFmt("Request already past deadline at dispatch: {s} {s}", .{ @tagName(request.head.method), target });
        ctx.res_status = .request_timeout;
        ctx.renderText("Request Timeout") catch {};
        if (server.metrics) |m| m.recordRequest(@intFromEnum(ctx.res_status));
        return;
    }

    server.router.execute(path, method, &ctx) catch |err| {
        // Client gone / socket already closed (idle close, RST, write deadline).
        // Do not attempt a 500 body — that just logs another WriteFailed.
        if (err == error.WriteFailed) {
            getLog().warnFmt("WriteFailed (client closed or write deadline): {s} {s}", .{ @tagName(request.head.method), target });
            if (server.metrics) |m| m.recordError("WriteFailed", path);
            return error.WriteFailed;
        }
        if (ctx.isExpired()) {
            getLog().warnFmt("Request timed out in handler: {s} {s}", .{ @tagName(request.head.method), target });
            ctx.res_status = .request_timeout;
            ctx.renderText("Request Timeout") catch {};
        } else {
            getLog().errFmt("Handler error: {} for {s} {s}", .{ err, @tagName(request.head.method), target });
            ctx.res_status = .internal_server_error;
            ctx.renderText("Internal Server Error") catch |render_err| {
                getLog().warnFmt("Failed to render 500 response: {t}", .{render_err});
            };
        }
        if (server.metrics) |m| {
            m.recordError(@errorName(err), path);
        }
    };

    if (server.metrics) |m| {
        m.recordRequest(@intFromEnum(ctx.res_status));
        m.recordRoute(path);
        const end_ms = std.Io.Timestamp.now(io_instance.io, .awake).toMilliseconds();
        const dur: u64 = @intCast(@max(end_ms - start_ms, 0));
        m.recordLatencyMs(dur);
        m.recordRouteLatencyMs(path, dur);
    }

    // Zig http.Server keep-alive is unsafe until ziglang/zig#25017 (+ body drain).
    // Default forces close; opt-in via ServerConfig.force_connection_close=false.
    if (server.config.force_connection_close) {
        request.head.keep_alive = false;
    }
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

fn shutdownWatcher(io: std.Io, server: *Server) std.Io.Cancelable!void {
    while (!shutdown.isShuttingDown()) {
        io.sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch break;
    }
    if (shutdown.isShuttingDown() and !server.listener_closed.swap(true, .monotonic)) {
        getLog().info("Shutdown signal received, closing listener socket to unblock accept...", .{});
        server.listener.socket.close(io);
    }
}
