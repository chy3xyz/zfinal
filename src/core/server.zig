const std = @import("std");
const http = std.http;
const Router = @import("router.zig").Router;
const HttpMethod = @import("router.zig").HttpMethod;
const Context = @import("context.zig").Context;
const Metrics = @import("metrics.zig").Metrics;
const getLog = @import("logger.zig").getLogger;
const RequestLogger = @import("logger.zig").RequestLogger;
const shutdown = @import("shutdown.zig");
const io_instance = @import("../io_instance.zig");
const http_error = @import("http_error.zig");
const sockread = @import("sockread.zig");
const WebSocket = @import("../websocket/websocket.zig").WebSocket;
const WebSocketManager = @import("../websocket/manager.zig").WebSocketManager;
const ws_handshake = @import("../websocket/handshake.zig");
const IpExt = @import("../ext/ext_util.zig").IpExt;

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
    /// Per-request handler deadline (ms) on `Context` (`isExpired`).
    /// Idle time waiting on `receiveHead` is bounded by `read_timeout_ms`
    /// instead — do **not** spawn a second Io fiber per connection for that
    /// (it consumed `async_limit` slots and looked like "thread pool leak"
    /// after ~3–4 keep-alive connections). 0 disables. Default 30s.
    request_timeout_ms: u64 = 30_000,
    /// Per-read poll deadline (ms) for receiveHead/body via sockread.
    /// This is the real between-request idle limit. 0 = wait forever. Default 30s.
    read_timeout_ms: u64 = 30_000,
    /// Per-response write deadline (ms), wall-clock from the first `drain`
    /// of each request. Zig 0.17 removed `Operation.net_write`, so this is
    /// enforced in user space rather than via `operateTimeout`. 0 disables.
    /// Default matches request_timeout_ms. Prefer also terminating TLS/proxy
    /// write timeouts at the reverse proxy.
    write_timeout_ms: u64 = 30_000,
    /// Emit a structured access-log line per request (`RequestLogger.begin/
    /// finish`: method, path, status, duration_ms, bytes, ip). Off by default;
    /// when on, uses the configured global Logger backend.
    access_log: bool = false,
    /// When true (default), force one-request-per-connection to avoid
    /// Zig `http.Server` keep-alive / discardBody bugs (ziglang/zig#25017;
    /// still asserts on 0.17.0-dev.1422). Production: keep true and put client
    /// keep-alive on nginx/Caddy — `doc/reverse_proxy.md`.
    /// Set false only after full body-drain coverage + upstream fix + soak tests.
    force_connection_close: bool = true,
    /// Default `Context.compress_enabled` for responses (gzip when client accepts).
    compress_responses: bool = true,
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
    /// Typed app State from `ZFinal.setState`.
    app_state: @import("state.zig").Handle = .{},
    /// Optional WebSocket routes (`ZFinal.addWebSocket`). When set, Upgrade
    /// requests matching a route take over the TCP connection after 101.
    ws_manager: ?*WebSocketManager = null,
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
///
/// One Io task per connection (no per-conn watchdog fiber). With
/// `async_limit == thread_count`, a second fiber per conn halved capacity
/// and left slots stuck in `receiveHead` after keep-alive responses —
/// sequential curls died after ~3–4 OK replies (HTTP 000 / idle wait).
fn handleConn(io: std.Io, conn: std.Io.net.Stream, server: *Server) std.Io.Cancelable!void {
    defer _ = server.active_conns.fetchSub(1, .monotonic);
    _ = server.active_conns.fetchAdd(1, .monotonic);
    if (server.metrics) |m| m.recordConnection();

    // Populate the peer address once per connection. `Context.remote_addr`
    // was declared but never filled by the server — without it, client-IP
    // features (rate limiting, audit logs) silently degrade to "unknown".
    const peer_addr = IpExt.peerIpAddress(conn.socket.handle);

    var ws_took_over = false;
    defer {
        if (!ws_took_over) conn.close(io);
    }

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var reader = sockread.TimedIoReader.init(conn, &read_buf, server.config.read_timeout_ms);
    var writer = TimedWriter.init(conn, io, &write_buf, server.config.write_timeout_ms);
    var http_srv = http.Server.init(&reader.interface, &writer.interface);
    var req_count: usize = 0;

    while (req_count < server.config.max_requests_per_conn) : (req_count += 1) {
        var request = http_srv.receiveHead() catch break;
        writer.resetWriteDeadline();
        if (tryWebSocketUpgrade(&request, server, conn) catch |err| {
            getLog().warnFmt("WebSocket upgrade failed: {t}", .{err});
            break;
        }) {
            ws_took_over = true;
            break;
        }
        dispatch(&request, server, peer_addr) catch break;
        if (server.config.force_connection_close) break;
        if (request.head.version != .@"HTTP/1.1") break;
        if (!request.head.keep_alive) break;
    }
}

/// If the request is a WebSocket upgrade for a registered path, send 101 and
/// run the handler on `conn`. Returns true when the TCP socket is now owned by WS.
fn tryWebSocketUpgrade(request: *http.Server.Request, server: *Server, conn: std.Io.net.Stream) !bool {
    const mgr = server.ws_manager orelse return false;

    var upgrade_val: ?[]const u8 = null;
    var key_val: ?[]const u8 = null;
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "upgrade")) upgrade_val = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "sec-websocket-key")) key_val = h.value;
    }
    const upgrade = upgrade_val orelse return false;
    if (std.ascii.findIgnoreCasePos(upgrade, 0, "websocket") == null) return false;
    const key = key_val orelse return false;

    const target = request.head.target;
    const safe_target = if (target.len > 4096) target[0..4096] else target;
    const path = if (std.mem.indexOfScalar(u8, safe_target, '?')) |q| safe_target[0..q] else safe_target;
    const handler = mgr.findRoute(path) orelse return false;

    var accept_buf: [28]u8 = undefined;
    const accept = ws_handshake.acceptKey(key, &accept_buf);

    try request.respond("", .{
        .status = .switching_protocols,
        .extra_headers = &.{
            .{ .name = "Upgrade", .value = "websocket" },
            .{ .name = "Connection", .value = "Upgrade" },
            .{ .name = "Sec-WebSocket-Accept", .value = accept },
        },
    });

    const ws = try server.allocator.create(WebSocket);
    errdefer server.allocator.destroy(ws);
    ws.* = WebSocket.init(server.allocator, conn);
    // Snapshot the handshake target so handlers can read query params
    // (e.g. `ws.queryParam("room_id")`) — the request Context is gone by now.
    ws.handshake_target = try server.allocator.dupe(u8, safe_target);
    try mgr.addConnection(ws);
    defer {
        mgr.removeConnection(ws);
        // Close TCP here; handleConn skips its defer close when we return true.
        ws.deinit();
        server.allocator.destroy(ws);
    }

    handler(ws) catch |err| {
        getLog().warnFmt("WebSocket handler error on {s}: {t}", .{ path, err });
    };
    return true;
}

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

fn monoMs(io: std.Io) u64 {
    const ts = std.Io.Timestamp.now(io, .awake);
    return @intCast(@max(ts.toMilliseconds(), 0));
}

fn dispatch(request: *http.Server.Request, server: *Server, peer_addr: ?std.Io.net.IpAddress) !void {
    const target = request.head.target;
    const safe_target = if (target.len > 4096) target[0..4096] else target;
    const path = if (std.mem.indexOfScalar(u8, safe_target, '?')) |q| safe_target[0..q] else safe_target;
    const method = HttpMethod.fromString(@tagName(request.head.method)) orelse .GET;
    const start_ms: i64 = std.Io.Timestamp.now(io_instance.io, .awake).toMilliseconds();

    // Structured access log (opt-in via ServerConfig.access_log). The
    // formatted peer string borrows a stack buffer; finish() runs inside this
    // dispatch frame, so it stays valid.
    var access_log: ?RequestLogger = null;
    if (server.config.access_log) {
        var ip_buf: [64]u8 = undefined;
        const remote_str: ?[]const u8 = if (peer_addr) |addr|
            IpExt.formatIpAddress(addr, &ip_buf)
        else
            null;
        access_log = RequestLogger.begin(getLog(), @tagName(request.head.method), path, remote_str);
    }

    // MUST run before respond(): `Context.render*` copies `req.head.keep_alive`
    // into the response. Setting this only after execute left Connection:
    // keep-alive on the wire, so handleConn waited on receiveHead#2 and held
    // an async slot until read timeout — slot exhaustion after a few curls.
    if (server.config.force_connection_close) {
        request.head.keep_alive = false;
    }

    var ctx = Context.init(request, server.allocator);
    ctx.remote_addr = peer_addr;
    ctx.cacheHeaders(); // snapshot headers before the body can invalidate them
    ctx.max_body_size = server.config.max_body_size;
    ctx.compress_enabled = server.config.compress_responses;
    ctx.app_state = server.app_state;
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
        http_error.render(&ctx, error.RequestTimeout) catch {};
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
            http_error.render(&ctx, error.RequestTimeout) catch {};
        } else if (http_error.isHttpError(err)) {
            http_error.render(&ctx, err) catch |render_err| {
                getLog().warnFmt("Failed to render HttpError response: {t}", .{render_err});
            };
        } else {
            getLog().errFmt("Handler error: {} for {s} {s}", .{ err, @tagName(request.head.method), target });
            http_error.render(&ctx, error.InternalServerError) catch |render_err| {
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

    if (access_log) |*rl| {
        rl.finish(@intFromEnum(ctx.res_status), ctx.response_bytes);
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
