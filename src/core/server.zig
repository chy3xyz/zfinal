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
    /// Idle / header reads use absolute sockread deadlines below — do **not**
    /// spawn a second Io fiber per connection for that (it consumed
    /// `async_limit` slots). 0 disables. Default 30s.
    request_timeout_ms: u64 = 30_000,
    /// Absolute wall-clock deadline (ms) to finish `receiveHead` on the first
    /// request of a connection (Lighting `read_header_timeout`). Defends
    /// against Slowloris — relative poll timeouts reset on each byte.
    /// 0 = fall back to `read_timeout_ms`. Default 5s.
    read_header_timeout_ms: u64 = 5_000,
    /// Absolute deadline (ms) waiting for the next request on a keep-alive
    /// connection (Lighting `idle_timeout`). 0 = fall back to `read_timeout_ms`.
    /// Default 120s.
    idle_timeout_ms: u64 = 120_000,
    /// Absolute deadline (ms) for body reads after the request head is received.
    /// 0 = wait forever. Default 30s.
    read_timeout_ms: u64 = 30_000,
    /// Max unread request body to discard before respond (Lighting
    /// `maxPostHandlerReadBytes`). Over this limit forces Connection: close.
    /// Default 256 KiB.
    max_drain_body_bytes: usize = 256 * 1024,
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
    /// Biggest throughput lever vs Lighting-style servers (true keep-alive).
    force_connection_close: bool = true,
    /// Default `Context.compress_enabled` for responses (gzip when client accepts).
    compress_responses: bool = true,
    /// Skip gzip below this body size (bytes). Lighting-style: small JSON
    /// APIs pay more for flate window than they save. Default 4 KiB.
    compress_min_bytes: usize = 4096,
    /// Per-connection `receiveHead` / body read buffer size. Lighting uses
    /// 8–16 KiB; larger buffers cut syscall chatter on pipelined/keep-alive.
    conn_read_buffer_bytes: usize = 8192,
};

/// Error set for server operations. Wrapped to fit Group.async std.Io.Cancelable!void constraint.
pub const ServerError = error{
    ListenFailed,
    AcceptFailed,
    AddressInvalid,
};

/// How long the drain keeps waiting after it interrupted the connections.
/// The group await is what actually waits for the handlers to unwind; this
/// only bounds how long the shutdown reports connections that are still
/// counted as active.
const interrupt_grace_ms: u64 = 2_000;

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
    /// The connections currently being served.
    ///
    /// The drain path needs them: a WebSocket never ends on its own, so
    /// the shutdown has to interrupt the connections instead of waiting
    /// for them to finish.
    conns: std.ArrayList(std.Io.net.Stream) = .empty,
    conns_mutex: std.Io.Mutex = .init,
    /// Set once the connections were interrupted, so a connection that
    /// arrives during the shutdown is interrupted as well.
    conns_interrupted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator, router: *Router, config: ServerConfig) !Server {
        return .{ .allocator = allocator, .router = router, .config = config };
    }

    /// Remember a connection so the shutdown path can interrupt it.
    fn registerConn(self: *Server, io: std.Io, conn: std.Io.net.Stream) void {
        self.conns_mutex.lockUncancelable(io);
        defer self.conns_mutex.unlock(io);
        if (self.conns_interrupted.load(.monotonic)) {
            // The shutdown already went through: this connection must not
            // be allowed to start a long-lived session.
            conn.shutdown(io, .both) catch {};
            return;
        }
        self.conns.append(self.allocator, conn) catch {};
    }

    /// Forget a connection that is no longer served.
    fn unregisterConn(self: *Server, io: std.Io, conn: std.Io.net.Stream) void {
        self.conns_mutex.lockUncancelable(io);
        defer self.conns_mutex.unlock(io);
        for (self.conns.items, 0..) |known, i| {
            if (known.socket.handle == conn.socket.handle) {
                _ = self.conns.swapRemove(i);
                return;
            }
        }
    }

    /// Interrupt every connection that is still being served.
    ///
    /// `shutdown` (not `close`): a blocked read has to wake up with an EOF,
    /// and closing the descriptor from another task would leave that read
    /// hanging on a descriptor that may already be reused.
    fn interruptConnections(self: *Server, io: std.Io) void {
        self.conns_interrupted.store(true, .monotonic);
        self.conns_mutex.lockUncancelable(io);
        defer self.conns_mutex.unlock(io);
        for (self.conns.items) |conn| {
            conn.shutdown(io, .both) catch {};
        }
    }

    /// Release what the server owns.
    ///
    /// The router, the websocket manager and the application state belong to
    /// the caller — they are not touched here.
    pub fn deinit(self: *Server) void {
        self.conns.deinit(self.allocator);
        self.conns = .empty;
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
        // Exactly one of the two paths may close the listener: this one
        // (the accept loop is over) and the shutdown watcher (it closes
        // the socket to unblock a pending accept()). `swap` makes the
        // winner the only closer — a plain `load` let both run and the
        // second close hit EBADF, which Zig turns into a panic.
        if (!server.listener_closed.swap(true, .monotonic)) {
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

        // The shutdown may have arrived while accept() was blocked. The
        // connection that just came in is then the wake-up the shutdown
        // watcher sent, not real traffic: drop it and stop accepting.
        if (shutdown.isShuttingDown()) {
            conn.close(io);
            break;
        }

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
                "Drain timeout ({d}ms) reached with {d} active connection(s); interrupting them",
                .{ drain_deadline_ms, server.active_conns.load(.monotonic) },
            );
            // The connections are not going to end on their own — a
            // WebSocket never does. Interrupt them instead of cancelling
            // the task group: this loop runs *inside* that group, and
            // `Server.start` is already awaiting it. Zig's group can only
            // be awaited or cancelled, never both — cancelling here
            // trips `assert(!pre_cancel_status.have_awaiter)` and kills
            // the process with "panic: reached unreachable code".
            server.interruptConnections(io);
            // Give the handlers a moment to unwind on the EOF. The group
            // await is what actually waits for them; this only keeps the
            // shutdown from reporting connections that are already gone.
            const grace_deadline_ms = waited_ms + interrupt_grace_ms;
            while (server.active_conns.load(.monotonic) > 0 and waited_ms < grace_deadline_ms) {
                io.sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch break;
                waited_ms += 100;
            }
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

    // Remember the connection so the shutdown path can interrupt it.
    server.registerConn(io, conn);
    defer server.unregisterConn(io, conn);

    // Populate the peer address once per connection. `Context.remote_addr`
    // was declared but never filled by the server — without it, client-IP
    // features (rate limiting, audit logs) silently degrade to "unknown".
    const peer_addr = IpExt.peerIpAddress(conn.socket.handle);

    var ws_took_over = false;
    defer {
        if (!ws_took_over) conn.close(io);
    }

    // Cap stack buffers: Zig forbids runtime-sized stack arrays. Config can
    // raise the logical size later via a heap path; 8 KiB matches Lighting.
    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    const read_slice = read_buf[0..@min(read_buf.len, server.config.conn_read_buffer_bytes)];
    var reader = sockread.TimedIoReader.init(conn, read_slice, server.config.read_timeout_ms);
    var writer = TimedWriter.init(conn, io, &write_buf, server.config.write_timeout_ms);
    var http_srv = http.Server.init(&reader.interface, &writer.interface);
    var req_count: usize = 0;

    while (req_count < server.config.max_requests_per_conn) : (req_count += 1) {
        // Between keep-alive requests: exit promptly on shutdown instead of
        // waiting for the next read timeout (matters when read_timeout_ms = 0).
        if (shutdown.isShuttingDown()) break;

        // First request: short absolute header deadline (Slowloris).
        // Later KA waits: longer idle deadline, then the same receiveHead path.
        const head_ms = if (req_count == 0) blk: {
            break :blk if (server.config.read_header_timeout_ms != 0)
                server.config.read_header_timeout_ms
            else
                server.config.read_timeout_ms;
        } else blk: {
            break :blk if (server.config.idle_timeout_ms != 0)
                server.config.idle_timeout_ms
            else
                server.config.read_timeout_ms;
        };
        if (head_ms == 0)
            reader.clearDeadline()
        else
            reader.setDeadlineFromNow(head_ms);

        var request = http_srv.receiveHead() catch break;

        // Body / remainder of this request: absolute `read_timeout_ms`.
        if (server.config.read_timeout_ms == 0)
            reader.clearDeadline()
        else
            reader.setDeadlineFromNow(server.config.read_timeout_ms);

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
    // A stalled WS peer must not pin the fiber forever; reuse the HTTP read
    // deadline for frame reads (0 keeps the old unbounded behavior).
    ws.read_timeout_ms = @intCast(@min(server.config.read_timeout_ms, std.math.maxInt(i32)));
    // Snapshot the handshake target so handlers can read query params
    // (e.g. `ws.queryParam("room_id")`) — the request Context is gone by now.
    ws.handshake_target = try server.allocator.dupe(u8, safe_target);
    try mgr.addConnection(ws);
    defer {
        // Drop the list reference, then the handler's creation reference. The
        // last unref closes the socket and frees the object, so a concurrent
        // broadcast/ping snapshot can never touch freed memory.
        mgr.removeConnection(ws);
        ws.unref();
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
        // Zig 0.17-dev.19xx: socket writes go through `Io.Operation`
        // (`VTable.netWrite` was removed); this mirrors `std.Io.net.Stream.Writer.drain`.
        const result = w.io.operate(.{ .net_write = .{
            .socket_handle = w.stream.socket.handle,
            .header = io_w.buffered(),
            .data = data,
            .splat = splat,
        } }) catch |err| {
            w.err = err;
            return error.WriteFailed;
        };
        const n = result.net_write catch |err| {
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
    // Lazy header cache (Lighting-style zero-copy until body): `getHeader`
    // walks `iterateHeaders` while still in `.received_head`; body readers
    // call `cacheHeaders` immediately before consuming the body.
    ctx.max_body_size = server.config.max_body_size;
    ctx.max_drain_body_bytes = server.config.max_drain_body_bytes;
    ctx.compress_enabled = server.config.compress_responses;
    ctx.compress_min_bytes = server.config.compress_min_bytes;
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
        if (server.metrics) |m| m.recordRequest(@backingInt(ctx.res_status));
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
        m.recordRequest(@backingInt(ctx.res_status));
        m.recordRoute(path);
        const end_ms = std.Io.Timestamp.now(io_instance.io, .awake).toMilliseconds();
        const dur: u64 = @intCast(@max(end_ms - start_ms, 0));
        m.recordLatencyMs(dur);
        m.recordRouteLatencyMs(path, dur);
    }

    if (access_log) |*rl| {
        rl.finish(@backingInt(ctx.res_status), ctx.response_bytes);
    }
}

// ============================================================
// Group.async wrappers — constrain return type to std.Io.Cancelable!void
// ============================================================

fn acceptLoop(io: std.Io, server: *Server, addr: std.Io.net.IpAddress, group: *std.Io.Group) std.Io.Cancelable!void {
    acceptLoopImpl(io, server, addr, group) catch |e| {
        getLog().errFmt("Server fatal error: {}", .{e});
        server.err_handle.set();
        // Stop the server the way a signal does: ask for the shutdown and
        // interrupt the connections. Cancelling the group is not an option
        // here — `Server.start` is already awaiting it, and a group can
        // only be awaited or cancelled, never both.
        shutdown.requestShutdown();
        server.interruptConnections(io);
    };
}

fn shutdownWatcher(io: std.Io, server: *Server) std.Io.Cancelable!void {
    while (!shutdown.isShuttingDown()) {
        io.sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch break;
    }
    if (shutdown.isShuttingDown() and !server.listener_closed.swap(true, .monotonic)) {
        getLog().info("Shutdown signal received, closing listener socket to unblock accept...", .{});
        // Closing the descriptor alone does not wake a thread that is
        // already blocked in accept(): Linux keeps the accept waiting on
        // the now invalid descriptor, so the accept loop never returns
        // and the server never stops. Darwin does wake it, which is why
        // this only shows up on Linux.
        //
        // The portable way out is to let the listener accept one more
        // connection: a self-connect completes the TCP handshake, the
        // pending accept() returns with it, and the accept loop sees
        // the shutdown flag and stops. The connection is closed right
        // away — it is a wake-up, not traffic.
        wakeupAccept(io, server);
        server.listener.socket.close(io);
    }
}

/// Wake a blocked accept() by connecting to the listener itself.
///
/// The listener has to be listening on a real port for this to work; a
/// failure here is not fatal — the shutdown still closes the socket, and
/// the accept loop may be woken by that instead.
fn wakeupAccept(io: std.Io, server: *Server) void {
    const port = server.listener.socket.address.getPort();
    if (port == 0) return;
    // A wildcard bind is reachable through the loopback address; a
    // specific bind is only reachable through its own address.
    const host = if (std.mem.eql(u8, server.config.host, "0.0.0.0"))
        "127.0.0.1"
    else
        server.config.host;
    const addr = std.Io.net.IpAddress.parseIp4(host, port) catch return;
    const conn = addr.connect(io, .{ .mode = .stream }) catch return;
    conn.close(io);
}
