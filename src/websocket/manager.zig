const std = @import("std");
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
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) WebSocketManager {
        return WebSocketManager{
            .routes = std.ArrayList(WebSocketRoute).init(allocator),
            .connections = std.ArrayList(*WebSocket).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WebSocketManager) void {
        self.routes.deinit();

        // 关闭所有连接
        for (self.connections.items) |ws| {
            ws.close();
            self.allocator.destroy(ws);
        }
        self.connections.deinit();
    }

    /// 添加 WebSocket 路由
    pub fn addRoute(self: *WebSocketManager, path: []const u8, handler: Handler) !void {
        try self.routes.append(.{
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
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.connections.append(ws);
    }

    /// 移除连接
    pub fn removeConnection(self: *WebSocketManager, ws: *WebSocket) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connections.items, 0..) |conn, i| {
            if (conn == ws) {
                _ = self.connections.orderedRemove(i);
                break;
            }
        }
    }

    /// 广播消息到所有连接
    pub fn broadcast(self: *WebSocketManager, message: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connections.items) |ws| {
            ws.sendText(message) catch |err| {
                std.debug.print("Broadcast error: {}\n", .{err});
            };
        }
    }

    /// 广播消息到所有连接（除了指定的）
    pub fn broadcastExcept(self: *WebSocketManager, message: []const u8, except: *WebSocket) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connections.items) |ws| {
            if (ws != except) {
                ws.sendText(message) catch |err| {
                    std.debug.print("Broadcast error: {}\n", .{err});
                };
            }
        }
    }
};
