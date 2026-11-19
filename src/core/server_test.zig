//! Regression coverage for the server shutdown path.
//!
//! A server that is asked to stop while a connection is still open used to
//! die with "panic: reached unreachable code". The drain path called
//! `Group.cancel` on the very group `Server.start` was already awaiting, and
//! Zig's group can only be awaited *or* cancelled, never both — the second
//! completion trips `assert(!pre_cancel_status.have_awaiter)`.
//!
//! The connection that makes this happen is the ordinary one: a WebSocket
//! that never ends on its own. The test opens one, asks the server to stop,
//! and waits for `Server.start` to come back on its own.

const std = @import("std");
const Server = @import("server.zig").Server;
const Router = @import("router.zig").Router;
const shutdown = @import("shutdown.zig");
const WebSocket = @import("../websocket/websocket.zig").WebSocket;
const WebSocketManager = @import("../websocket/manager.zig").WebSocketManager;

/// Wait for a while. Zig 0.17 dropped `std.Thread.sleep` — the Io is the
/// only clock left.
fn sleepMs(io: std.Io, ms: u64) void {
    io.sleep(std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

/// Holds the WebSocket open until the server interrupts it.
///
/// The client never sends a frame and never closes: the connection is only
/// released by the shutdown, which is the situation that used to panic.
fn holdConnectionOpen(ws: *WebSocket) anyerror!void {
    while (true) {
        _ = ws.receive() catch break;
    }
}

/// The server runs on its own thread — `Server.start` blocks until the
/// server stops.
const ServerRun = struct {
    server: *Server,
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *ServerRun) void {
        self.server.start() catch {
            self.failed.store(true, .monotonic);
        };
        self.finished.store(true, .monotonic);
    }
};

test "the server shuts down cleanly while a WebSocket is still open" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The shutdown flag is process-wide. Other test modules leave it set
    // (their servers shut themselves down), and a server that starts with
    // the flag set skips the accept loop entirely — so take it over here
    // and hand it back when the test is over.
    const flag_was_set = shutdown.isShuttingDown();
    shutdown.shutting_down.store(false, .monotonic);
    defer shutdown.shutting_down.store(flag_was_set, .monotonic);

    // A port that is free right now — the server binds it a moment later.
    const probe_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var probe = try probe_addr.listen(io, .{ .reuse_address = true });
    const port = probe.socket.address.getPort();
    probe.deinit(io);

    var router = Router.init(allocator);
    defer router.deinit();

    var ws_manager = WebSocketManager.init(allocator);
    defer ws_manager.deinit();
    try ws_manager.addRoute("/ws", holdConnectionOpen);

    var server = try Server.init(allocator, &router, .{
        .host = "127.0.0.1",
        .port = port,
        .thread_count = 4,
        // The drain gives up quickly, and the connection has no read
        // timeout of its own: only the shutdown may release it. That is
        // exactly the situation that used to panic.
        .drain_timeout_ms = 300,
        .read_timeout_ms = 0,
        .write_timeout_ms = 0,
    });
    defer server.deinit();
    server.ws_manager = &ws_manager;

    var run = ServerRun{ .server = &server };
    const thread = try std.Thread.spawn(.{}, ServerRun.run, .{&run});
    // The join has to happen before `server.deinit` frees what the server
    // thread still touches.
    //
    // It is deliberately conditional: joining only returns once the
    // server is done, and a server that does not stop is exactly the
    // situation this regression is about. An unconditional join would
    // block the whole test suite — and the CI job — forever instead of
    // reporting the failure.
    var server_done = false;
    defer if (server_done) thread.join();

    // Wait until the server accepts connections.
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var conn: ?std.Io.net.Stream = null;
    for (0..100) |_| {
        conn = addr.connect(io, .{ .mode = .stream }) catch {
            sleepMs(io, 20);
            continue;
        };
        break;
    }
    const stream = conn orelse return error.ServerNeverListened;
    // Only on the failure path: closing the client socket early would end
    // the WebSocket handler on its own, the server would drain normally,
    // and the drain timeout would never be reached — the exact situation
    // this regression is about.
    errdefer stream.close(io);

    // The WebSocket handshake. From here on the connection is open and
    // idle — the client sends nothing and never closes.
    var write_buf: [512]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(
        "GET /ws HTTP/1.1\r\n" ++
            "Host: 127.0.0.1\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "Sec-WebSocket-Version: 13\r\n\r\n",
    );
    try writer.interface.flush();

    // The handshake has to complete before the connection counts as
    // served — otherwise the shutdown would race the upgrade.
    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var head: [1024]u8 = undefined;
    var head_len: usize = 0;
    while (head_len < head.len) {
        const line = try reader.interface.takeDelimiterInclusive('\n');
        if (head_len + line.len > head.len) return error.ResponseHeadTooLong;
        @memcpy(head[head_len..][0..line.len], line);
        head_len += line.len;
        if (std.mem.endsWith(u8, head[0..head_len], "\r\n\r\n")) break;
    }
    try std.testing.expect(std.mem.startsWith(u8, head[0..head_len], "HTTP/1.1 101"));

    // Wait until the server counts the connection.
    var served = false;
    for (0..100) |_| {
        if (server.active_conns.load(.monotonic) > 0) {
            served = true;
            break;
        }
        sleepMs(io, 20);
    }
    try std.testing.expect(served);

    // Ask the server to stop while the connection is still open.
    shutdown.requestShutdown();

    // The server has to come back on its own. Before the fix it died with
    // "panic: reached unreachable code" inside the drain path.
    var stopped = false;
    for (0..250) |_| {
        if (run.finished.load(.monotonic)) {
            stopped = true;
            break;
        }
        sleepMs(io, 20);
    }
    if (!stopped) {
        // A server that does not stop cannot be joined — the join would
        // block forever. Report it and end the process: a test that hangs
        // takes the whole suite down with it and says nothing about what
        // went wrong.
        std.debug.print(
            "the server did not stop within 5000ms while a WebSocket was open\n",
            .{},
        );
        std.process.exit(70);
    }
    if (run.failed.load(.monotonic)) {
        std.debug.print("the server reported a fatal error during shutdown\n", .{});
        std.process.exit(71);
    }
    server_done = true;

    // Now that the server is done, the client socket can go.
    stream.close(io);
}
