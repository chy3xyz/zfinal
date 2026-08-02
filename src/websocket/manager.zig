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

        for (self.connections.items) |ws| {
            ws.deinit();
            self.allocator.destroy(ws);
        }
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

    /// 添加连接
    pub fn addConnection(self: *WebSocketManager, ws: *WebSocket) !void {
        try self.mutex.lock(io_instance.io);
        defer self.mutex.unlock(io_instance.io);
        try self.connections.append(self.allocator, ws);
    }

    /// 移除连接
    pub fn removeConnection(self: *WebSocketManager, ws: *WebSocket) void {
        self.mutex.lockUncancelable(io_instance.io);
        defer self.mutex.unlock(io_instance.io);

        for (self.connections.items, 0..) |conn, i| {
            if (conn == ws) {
                _ = self.connections.orderedRemove(i);
                break;
            }
        }
    }

    fn snapshot(self: *WebSocketManager) ![]*WebSocket {
        try self.mutex.lock(io_instance.io);
        defer self.mutex.unlock(io_instance.io);
        return try self.allocator.dupe(*WebSocket, self.connections.items);
    }

    /// 广播消息到所有连接（解锁后发送，避免持锁 I/O）
    pub fn broadcast(self: *WebSocketManager, message: []const u8) !void {
        const conns = try self.snapshot();
        defer self.allocator.free(conns);
        for (conns) |ws| {
            ws.sendText(message) catch {};
        }
    }

    /// 广播消息到所有连接（除了指定的）
    pub fn broadcastExcept(self: *WebSocketManager, message: []const u8, except: *WebSocket) !void {
        const conns = try self.snapshot();
        defer self.allocator.free(conns);
        for (conns) |ws| {
            if (ws != except) {
                ws.sendText(message) catch {};
            }
        }
    }

    /// Best-effort application ping to all live connections (idle probing).
    pub fn pingAll(self: *WebSocketManager, payload: []const u8) void {
        const conns = self.snapshot() catch return;
        defer self.allocator.free(conns);
        for (conns) |ws| {
            if (ws.closeIfIdle()) continue;
            ws.sendPing(payload);
        }
    }

    /// Close and drop connections that exceeded their idle timeout.
    pub fn reapIdle(self: *WebSocketManager) usize {
        const conns = self.snapshot() catch return 0;
        defer self.allocator.free(conns);
        var n: usize = 0;
        for (conns) |ws| {
            if (ws.closeIfIdle()) {
                self.removeConnection(ws);
                n += 1;
            }
        }
        return n;
    }
};
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
