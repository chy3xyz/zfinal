//! Echo via `ZFinal.addWebSocket` (Upgrade handled inside `Server`).
//!
//! ```
//! zig build run-ws
//! wscat -c ws://127.0.0.1:8080/ws
//! ```

const std = @import("std");
const zfinal = @import("zfinal");

fn echoHandler(ws: *zfinal.WebSocket) !void {
    while (true) {
        var frame = ws.receive() catch |err| {
            if (err == error.ConnectionClosed) break;
            return err;
        };
        defer frame.deinit();
        switch (frame.opcode) {
            .text => try ws.sendText(frame.payload),
            .binary => try ws.sendBinary(frame.payload),
            else => {},
        }
    }
}

pub fn main(init: std.process.Init) !void {
    zfinal.io_instance.init(init);
    const allocator = init.gpa;

    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();
    app.setConfig(.{ .port = 8080, .force_connection_close = true });

    try app.addWebSocket("/ws", echoHandler);
    try app.get("/health", struct {
        fn h(ctx: *zfinal.Context) !void {
            try ctx.renderJson(.{ .ok = true, .ws = "/ws" });
        }
    }.h);

    std.log.info("websocket echo on ws://127.0.0.1:8080/ws", .{});
    try app.start();
}
