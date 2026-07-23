//! Keep-alive safety helpers for Zig `std.http.Server`.
//!
//! Upstream [zig#25017](https://github.com/ziglang/zig/issues/25017) still asserts in
//! `discardBody` on Zig `0.17.0-dev.1422` when `keep_alive` is true and a body-bearing
//! method lacks Content-Length / Transfer-Encoding. Production default remains
//! `force_connection_close=true` + reverse-proxy client keep-alive
//! (`doc/reverse_proxy.md`). These helpers harden the drain path when respond runs.

const std = @import("std");
const http = std.http;

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

/// Drain any unread request body after `prepareRequestBodyForRespond`.
pub fn drainPreparedBody(req: *http.Server.Request) void {
    prepareRequestBodyForRespond(req);
    if (!req.head.method.requestHasBody()) return;
    if (req.server.reader.state != .received_head) return;

    var drain_buf: [4096]u8 = undefined;
    var drain_reader = req.readerExpectNone(&drain_buf);
    _ = drain_reader.discardRemaining() catch {};
}

test "ServerConfig force_connection_close defaults true" {
    const ServerConfig = @import("server.zig").ServerConfig;
    const cfg: ServerConfig = .{};
    try std.testing.expect(cfg.force_connection_close);
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
                        drainPreparedBody(&req);
                        // Cap the loop — do not wait forever on keep-alive
                        req.head.keep_alive = nreq < 1;
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
