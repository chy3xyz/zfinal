const std = @import("std");
const io_instance = @import("../io_instance.zig");
const WebSocket = @import("websocket.zig").WebSocket;

/// WebSocket 处理器
pub const Handler = *const fn (ws: *WebSocket) anyerror!void;

/// WebSocket 路由
pub const WebSocketRoute = struct {
    path: []const u8,
    handler: Handler,
};

/// WebSocket 管理器
pub const WebSocketManager = struct {
    routes: std.ArrayList(WebSocketRoute),
    connections: std.ArrayList(*WebSocket),
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = std.Io.Mutex.init,

    pub fn init(allocator: std.mem.Allocator) WebSocketManager {
        return WebSocketManager{
            .routes = std.ArrayList(WebSocketRoute).empty,
            .connections = std.ArrayList(*WebSocket).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WebSocketManager) void {
        self.routes.deinit(self.allocator);

        // Release the list references. Connections still held by a handler or
        // an in-flight snapshot free themselves on their last unref.
        for (self.connections.items) |ws| ws.unref();
        self.connections.deinit(self.allocator);
        self.* = undefined;
    }

    /// 添加 WebSocket 路由
    pub fn addRoute(self: *WebSocketManager, path: []const u8, handler: Handler) !void {
        try self.routes.append(self.allocator, .{
            .path = path,
            .handler = handler,
        });
    }

    /// 查找路由
    pub fn findRoute(self: *WebSocketManager, path: []const u8) ?Handler {
        for (self.routes.items) |route| {
            if (std.mem.eql(u8, route.path, path)) {
                return route.handler;
            }
        }
        return null;
    }

    /// 添加连接。Adds a reference held by the manager list.
    pub fn addConnection(self: *WebSocketManager, ws: *WebSocket) !void {
        try self.mutex.lock(io_instance.io);
        defer self.mutex.unlock(io_instance.io);
        try self.connections.append(self.allocator, ws);
        ws.ref();
    }

    /// 移除连接。Drops the list reference; in-flight snapshots keep it alive.
    pub fn removeConnection(self: *WebSocketManager, ws: *WebSocket) void {
        const io = io_instance.io;
        self.mutex.lockUncancelable(io);
        var found = false;
        for (self.connections.items, 0..) |conn, i| {
            if (conn == ws) {
                _ = self.connections.orderedRemove(i);
                found = true;
                break;
            }
        }
        self.mutex.unlock(io);
        if (found) ws.unref();
    }

    /// Copy the connection list, holding a reference on each entry. The caller
    /// MUST pass the slice to `releaseSnapshot`.
    fn snapshotRefs(self: *WebSocketManager) ![]*WebSocket {
        try self.mutex.lock(io_instance.io);
        defer self.mutex.unlock(io_instance.io);
        const out = try self.allocator.dupe(*WebSocket, self.connections.items);
        for (out) |ws| ws.ref();
        return out;
    }

    fn releaseSnapshot(self: *WebSocketManager, conns: []*WebSocket) void {
        for (conns) |ws| ws.unref();
        self.allocator.free(conns);
    }

    /// 广播消息到所有连接（解锁后发送，避免持锁 I/O）
    pub fn broadcast(self: *WebSocketManager, message: []const u8) !void {
        const conns = try self.snapshotRefs();
        defer self.releaseSnapshot(conns);
        for (conns) |ws| {
            ws.sendText(message) catch {};
        }
    }

    /// 广播消息到所有连接（除了指定的）
    pub fn broadcastExcept(self: *WebSocketManager, message: []const u8, except: *WebSocket) !void {
        const conns = try self.snapshotRefs();
        defer self.releaseSnapshot(conns);
        for (conns) |ws| {
            if (ws != except) {
                ws.sendText(message) catch {};
            }
        }
    }

    /// Best-effort application ping to all live connections (idle probing).
    pub fn pingAll(self: *WebSocketManager, payload: []const u8) void {
        const conns = self.snapshotRefs() catch return;
        defer self.releaseSnapshot(conns);
        for (conns) |ws| {
            if (ws.closeIfIdle()) continue;
            ws.sendPing(payload);
        }
    }

    /// Close and drop connections that exceeded their idle timeout.
    pub fn reapIdle(self: *WebSocketManager) usize {
        const conns = self.snapshotRefs() catch return 0;
        defer self.releaseSnapshot(conns);
        var n: usize = 0;
        for (conns) |ws| {
            if (ws.closeIfIdle()) {
                self.removeConnection(ws);
                n += 1;
            }
        }
        return n;
    }

    pub const IdleTickResult = struct {
        reaped: usize = 0,
    };

    /// Periodic hook: reap idle sockets, then ping survivors.
    /// Wire from `CronPlugin.scheduleWith` / task scheduler, e.g. `*/30 * * * * *`.
    pub fn tickIdle(self: *WebSocketManager, ping_payload: []const u8) IdleTickResult {
        const reaped = self.reapIdle();
        self.pingAll(ping_payload);
        return .{ .reaped = reaped };
    }

    /// Cron/`scheduleWith` callback: `context` must be `*WebSocketManager`.
    pub fn cronTickIdle(ctx: *anyopaque) void {
        const self: *WebSocketManager = @ptrCast(@alignCast(ctx));
        _ = self.tickIdle("zfinal-ws-idle");
    }
};
test "WebSocketManager snapshot keeps a removed connection alive (no UAF)" {
    const a = std.testing.allocator;
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (std.posix.errno(rc) != .SUCCESS) return error.SkipZigTest;
    defer _ = std.posix.system.close(fds[1]); // fds[0] is owned by the WebSocket

    var mgr = WebSocketManager.init(a);
    defer mgr.deinit();

    const ws = try a.create(WebSocket);
    ws.* = WebSocket.init(a, .{ .socket = .{ .handle = fds[0], .address = undefined } });
    try mgr.addConnection(ws);

    const snap = try mgr.snapshotRefs();
    mgr.removeConnection(ws); // drops the list reference
    ws.unref(); // drops the creator reference, as server.zig does on handler exit
    // Only the snapshot reference remains: the object must stay alive. Freeing
    // it here would be a use-after-free for the concurrent broadcaster.
    try std.testing.expect(!ws.closed.load(.monotonic));
    mgr.releaseSnapshot(snap); // last ref: closes fds[0] and frees ws
}

test "WebSocketManager route lookup" {
    const a = std.testing.allocator;
    var mgr = WebSocketManager.init(a);
    defer mgr.deinit();
    try mgr.addRoute("/ws", struct {
        fn h(_: *WebSocket) !void {}
    }.h);
    try std.testing.expect(mgr.findRoute("/ws") != null);
    try std.testing.expect(mgr.findRoute("/other") == null);
}
