//! Keep-alive safety helpers for Zig `std.http.Server`.
//!
//! Upstream [zig#25017](https://github.com/ziglang/zig/issues/25017) still asserts in
//! `discardBody` on Zig `0.17.0-dev.1422` when `keep_alive` is true and a body-bearing
//! method lacks Content-Length / Transfer-Encoding. Production default remains
//! `force_connection_close=true` + reverse-proxy client keep-alive
//! (`doc/reverse_proxy.md`). These helpers harden the drain path when respond runs.
//!
//! Bounded drain (Lighting `maxPostHandlerReadBytes` = 256 KiB): discard at most
//! N unread body bytes before respond; over the limit → caller must close the
//! connection (anti-DoS + KA framing safety).

const std = @import("std");
const http = std.http;

/// Default unread-body drain ceiling (Lighting-aligned).
pub const default_max_drain_body_bytes: usize = 256 * 1024;

pub const DrainResult = enum {
    /// No body, or fully drained within the limit.
    ok,
    /// More than `max_bytes` remain unread — close the connection.
    too_large,
    /// I/O or protocol error while draining.
    failed,
};

/// Before `respond` / streaming: if the method may have a body but the client omitted
/// length headers, treat the body as empty so `discardBody` does not assert.
pub fn prepareRequestBodyForRespond(req: *http.Server.Request) void {
    if (!req.head.method.requestHasBody()) return;
    if (req.server.reader.state != .received_head) return;

    const has_content_length = req.head.content_length != null;
    const is_chunked = req.head.transfer_encoding != .none;
    if (!has_content_length and !is_chunked) {
        req.head.content_length = 0;
    }
}

/// Drain any unread request body after `prepareRequestBodyForRespond`, up to
/// `max_bytes` (use `default_max_drain_body_bytes` when unsure).
pub fn drainPreparedBody(req: *http.Server.Request, max_bytes: usize) DrainResult {
    prepareRequestBodyForRespond(req);
    if (!req.head.method.requestHasBody()) return .ok;
    if (req.server.reader.state != .received_head) return .ok;

    var drain_buf: [4096]u8 = undefined;
    var drain_reader = req.readerExpectNone(&drain_buf);

    var total: usize = 0;
    while (total < max_bytes) {
        const want = @min(drain_buf.len, max_bytes - total);
        const n = drain_reader.discard(.limited(want)) catch |err| switch (err) {
            error.EndOfStream => return .ok,
            else => return .failed,
        };
        if (n == 0) return .ok;
        total += n;
        if (n < want) return .ok; // short read ⇒ EOF
    }

    // Hit the ceiling — one more byte means "too large to keep the connection".
    const extra = drain_reader.discard(.limited(1)) catch |err| switch (err) {
        error.EndOfStream => return .ok,
        else => return .failed,
    };
    if (extra > 0) return .too_large;
    return .ok;
}

test "ServerConfig force_connection_close defaults true" {
    const ServerConfig = @import("server.zig").ServerConfig;
    const cfg: ServerConfig = .{};
    try std.testing.expect(cfg.force_connection_close);
    try std.testing.expectEqual(@as(usize, default_max_drain_body_bytes), cfg.max_drain_body_bytes);
    try std.testing.expectEqual(@as(u64, 5_000), cfg.read_header_timeout_ms);
    try std.testing.expectEqual(@as(u64, 120_000), cfg.idle_timeout_ms);
}

test "POST methods are treated as body-bearing" {
    try std.testing.expect(http.Method.POST.requestHasBody());
    try std.testing.expect(http.Method.PUT.requestHasBody());
    try std.testing.expect(!http.Method.GET.requestHasBody());
}

fn runKaScenario(
    port: u16,
    wire: []const u8,
    comptime mode: enum { drain, force_close },
) !void {
    var da: std.heap.DebugAllocator(.{}) = .init;
    defer _ = da.deinit();
    const gpa = da.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    const Ctx = struct {
        io: std.Io,
        lis: *std.Io.net.Server,
        done: std.atomic.Value(bool) = .init(false),
    };
    var ctx: Ctx = .{ .io = io, .lis = &listener };

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(c: *Ctx) void {
            defer c.done.store(true, .release);
            const conn = c.lis.accept(c.io) catch return;
            defer conn.close(c.io);
            var rb: [4096]u8 = undefined;
            var wb: [4096]u8 = undefined;
            var r = conn.reader(c.io, &rb);
            var w = conn.writer(c.io, &wb);
            var http_srv = http.Server.init(&r.interface, &w.interface);
            var nreq: usize = 0;
            while (nreq < 4 and http_srv.reader.state == .ready) : (nreq += 1) {
                var req = http_srv.receiveHead() catch break;
                switch (mode) {
                    .drain => {
                        const result = drainPreparedBody(&req, default_max_drain_body_bytes);
                        if (result != .ok) {
                            req.head.keep_alive = false;
                        } else {
                            // Cap the loop — do not wait forever on keep-alive
                            req.head.keep_alive = nreq < 1;
                        }
                    },
                    .force_close => {
                        req.head.keep_alive = false;
                    },
                }
                req.respond("ok\n", .{}) catch break;
                if (!req.head.keep_alive) break;
            }
        }
    }.run, .{&ctx});

    // Give accept a moment
    io.sleep(std.Io.Duration.fromMilliseconds(20), .awake) catch {};

    const client_addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = try client_addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var wbuf: [512]u8 = undefined;
    var wr = stream.writer(io, &wbuf);
    try wr.interface.writeAll(wire);
    try wr.interface.flush();

    var rbuf: [1024]u8 = undefined;
    var rd = stream.reader(io, &rbuf);
    var out: [1024]u8 = undefined;
    const n = try rd.interface.readSliceShort(&out);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, out[0..n], "200") != null);

    thread.join();
    try std.testing.expect(ctx.done.load(.acquire));
}

test "keepalive: drain path survives #25017 pipelined POST without length" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    try runKaScenario(
        18765,
        "POST /x HTTP/1.1\r\nConnection: keep-alive\r\n\r\nGET /x HTTP/1.1\r\nConnection: keep-alive\r\n\r\n",
        .drain,
    );
}

test "keepalive: force keep_alive=false survives #25017 POST" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    try runKaScenario(
        18766,
        "POST /x HTTP/1.1\r\nConnection: keep-alive\r\n\r\n",
        .force_close,
    );
}

test "keepalive: oversized unread body forces connection close" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var da: std.heap.DebugAllocator(.{}) = .init;
    defer _ = da.deinit();
    const gpa = da.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const port: u16 = 18767;
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    const max_drain: usize = 1024;
    const body_len: usize = max_drain + 64;

    const Ctx = struct {
        io: std.Io,
        lis: *std.Io.net.Server,
        max_drain: usize,
        result: DrainResult = .ok,
        keep_alive_after: bool = true,
        done: std.atomic.Value(bool) = .init(false),
    };
    var ctx: Ctx = .{ .io = io, .lis = &listener, .max_drain = max_drain };

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(c: *Ctx) void {
            defer c.done.store(true, .release);
            const conn = c.lis.accept(c.io) catch return;
            defer conn.close(c.io);
            var rb: [8192]u8 = undefined;
            var wb: [4096]u8 = undefined;
            var r = conn.reader(c.io, &rb);
            var w = conn.writer(c.io, &wb);
            var http_srv = http.Server.init(&r.interface, &w.interface);
            var req = http_srv.receiveHead() catch return;
            // Do not read the body in the handler — drain path must catch it.
            c.result = drainPreparedBody(&req, c.max_drain);
            if (c.result != .ok) req.head.keep_alive = false;
            c.keep_alive_after = req.head.keep_alive;
            req.respond("ok\n", .{ .keep_alive = req.head.keep_alive }) catch {};
        }
    }.run, .{&ctx});

    io.sleep(std.Io.Duration.fromMilliseconds(20), .awake) catch {};

    const client_addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = try client_addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var head_buf: [128]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "POST /big HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n", .{body_len});
    var body: [max_drain + 64]u8 = undefined;
    @memset(&body, 'Z');

    var wbuf: [8192]u8 = undefined;
    var wr = stream.writer(io, &wbuf);
    try wr.interface.writeAll(head);
    try wr.interface.writeAll(body[0..body_len]);
    try wr.interface.flush();

    var rbuf: [1024]u8 = undefined;
    var rd = stream.reader(io, &rbuf);
    var out: [1024]u8 = undefined;
    _ = try rd.interface.readSliceShort(&out);

    thread.join();
    try std.testing.expect(ctx.done.load(.acquire));
    try std.testing.expectEqual(DrainResult.too_large, ctx.result);
    try std.testing.expect(!ctx.keep_alive_after);
}
