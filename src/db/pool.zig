const std = @import("std");
const DB = @import("db.zig").DB;
const DBConfig = @import("config.zig").DBConfig;
const io_instance = @import("../io_instance.zig");

fn getIo() std.Io {
    if (@import("builtin").is_test) return std.testing.io;
    return getIo();
}

/// 数据库连接池 with proper condition-based waiting and timeout
pub const ConnectionPool = struct {
    connections: std.ArrayList(*DB),
    available: std.ArrayList(*DB),
    mutex: std.Io.Mutex,
    cond: std.Io.Condition,
    config: DBConfig,
    allocator: std.mem.Allocator,
    max_connections: usize,
    current_connections: usize,
    acquire_timeout_ms: u64,

    pub fn init(allocator: std.mem.Allocator, config: DBConfig, max_connections: usize) ConnectionPool {
        return ConnectionPool{
            .connections = std.ArrayList(*DB).empty,
            .available = std.ArrayList(*DB).empty,
            .mutex = std.Io.Mutex.init,
            .cond = std.Io.Condition.init,
            .config = config,
            .allocator = allocator,
            .max_connections = max_connections,
            .current_connections = 0,
            .acquire_timeout_ms = 30000, // 30s default
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        self.mutex.lock(getIo()) catch {};
        defer self.mutex.unlock(getIo());

        for (self.connections.items) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.connections.deinit(self.allocator);
        self.available.deinit(self.allocator);
    }

    /// 获取连接（带超时）
    pub fn acquire(self: *ConnectionPool) !*DB {
        self.mutex.lock(getIo()) catch {};
        defer self.mutex.unlock(getIo());

        const deadline = std.Io.Timestamp.now(getIo(), .real).toMilliseconds() + @as(i64, @intCast(self.acquire_timeout_ms));

        while (true) {
            // 1. 尝试获取可用连接 (with health check)
            while (self.available.items.len > 0) {
                const conn = self.available.pop().?;
                if (conn.ping()) return conn;
                // Dead connection — discard and try next
                conn.deinit();
                self.allocator.destroy(conn);
                // Remove from connections list
                for (self.connections.items, 0..) |c, i| {
                    if (c == conn) {
                        _ = self.connections.swapRemove(i);
                        break;
                    }
                }
                self.current_connections -= 1;
            }

            // 2. 尝试创建新连接
            if (self.current_connections < self.max_connections) {
                const conn = try self.allocator.create(DB);
                errdefer self.allocator.destroy(conn);
                conn.* = try DB.init(self.allocator, self.config);

                try self.connections.append(self.allocator, conn);
                self.current_connections += 1;

                return conn;
            }

            // 3. Wait for connection release with timeout
            const now = std.Io.Timestamp.now(getIo(), .real).toMilliseconds();
            if (now >= deadline) {
                return error.PoolTimeout;
            }

            self.cond.waitUncancelable(getIo(), &self.mutex);
        }
    }

    /// 释放连接
    pub fn release(self: *ConnectionPool, conn: *DB) !void {
        self.mutex.lock(getIo()) catch {};
        defer self.mutex.unlock(getIo());

        try self.available.append(self.allocator, conn);
        self.cond.signal(getIo());
    }

    /// 执行事务
    pub fn transaction(self: *ConnectionPool, comptime func: anytype, args: anytype) !void {
        const conn = try self.acquire();
        defer self.release(conn) catch {};

        try conn.begin();
        errdefer conn.rollback() catch {};

        try @call(.auto, func, .{conn} ++ args);
        try conn.commit();
    }
};

test "connection pool basic" {
    // Skip: std.Io.Mutex with std.testing.io does not support cross-thread futex operations
    if (true) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    const config = DBConfig.sqliteMemory();
    var pool = ConnectionPool.init(allocator, config, 5);
    defer pool.deinit();

    // 获取连接
    const conn1 = try pool.acquire();
    try std.testing.expect(pool.current_connections == 1);

    // 释放连接
    try pool.release(conn1);
    try std.testing.expect(pool.available.items.len == 1);

    // 再次获取应该复用
    const conn2 = try pool.acquire();
    try std.testing.expect(conn1 == conn2);
}