const std = @import("std");
const DB = @import("db.zig").DB;
const DBConfig = @import("config.zig").DBConfig;
const mutex_init = @import("mutex_init.zig");

/// 数据库连接池 with POSIX thread synchronization.
///
/// Uses pthread_mutex_init / pthread_cond_init at runtime (not the
/// static INITIALIZER value-copied) to avoid the aarch64-macos bug
/// where PTHREAD_MUTEX_INITIALIZER (64-byte struct with magic bytes
/// 0x32AAABA7 + init flags) loses flags on struct copy, causing
/// pthread_mutex_lock to silently fail on worker threads.
pub const ConnectionPool = struct {
    connections: std.ArrayList(*DB),
    available: std.ArrayList(*DB),
    mutex: std.c.pthread_mutex_t,
    cond: std.c.pthread_cond_t,
    config: DBConfig,
    allocator: std.mem.Allocator,
    max_connections: usize,
    current_connections: usize,
    acquire_timeout_ms: u64,

    pub fn init(allocator: std.mem.Allocator, config: DBConfig, max_connections: usize) !ConnectionPool {
        var pool = ConnectionPool{
            .connections = std.ArrayList(*DB).empty,
            .available = std.ArrayList(*DB).empty,
            .mutex = undefined,
            .cond = undefined,
            .config = config,
            .allocator = allocator,
            .max_connections = max_connections,
            .current_connections = 0,
            .acquire_timeout_ms = 30000,
        };
        try mutex_init.initMutex(&pool.mutex);
        errdefer mutex_init.destroyMutex(&pool.mutex);
        try mutex_init.initCond(&pool.cond);
        return pool;
    }

    pub fn deinit(self: *ConnectionPool) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);

        for (self.connections.items) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.connections.deinit(self.allocator);
        self.available.deinit(self.allocator);
        mutex_init.destroyMutex(&self.mutex);
        mutex_init.destroyCond(&self.cond);
        self.* = undefined;
    }

    pub fn acquire(self: *ConnectionPool) !*DB {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);

        var now_ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &now_ts);
        const deadline_ms = @as(i64, @intCast(now_ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(now_ts.nsec)), 1_000_000) + @as(i64, @intCast(self.acquire_timeout_ms));

        while (true) {
            while (self.available.items.len > 0) {
                const conn = self.available.pop().?;
                if (conn.ping()) return conn;
                conn.deinit();
                self.allocator.destroy(conn);
                for (self.connections.items, 0..) |item, i| {
                    if (item == conn) {
                        _ = self.connections.swapRemove(i);
                        break;
                    }
                }
                self.current_connections -= 1;
            }

            if (self.current_connections < self.max_connections) {
                const conn = try self.allocator.create(DB);
                errdefer self.allocator.destroy(conn);
                conn.* = try DB.init(self.allocator, self.config);

                try self.connections.append(self.allocator, conn);
                self.current_connections += 1;
                return conn;
            }

            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &now_ts);
            const now_ms = @as(i64, @intCast(now_ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(now_ts.nsec)), 1_000_000);
            if (now_ms >= deadline_ms) {
                return error.PoolTimeout;
            }

            var ts: std.c.timespec = .{
                .sec = @divTrunc(deadline_ms, 1000),
                .nsec = @mod(deadline_ms, 1000) * 1_000_000,
            };
            const rc = std.c.pthread_cond_timedwait(&self.cond, &self.mutex, &ts);
            if (rc != .SUCCESS and rc != .INTR) {
                return error.PoolTimeout;
            }
        }
    }

    pub fn release(self: *ConnectionPool, conn: *DB) !void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);

        try self.available.append(self.allocator, conn);
        _ = std.c.pthread_cond_signal(&self.cond);
    }

    pub fn keepAlive(self: *ConnectionPool) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);

        var i: usize = 0;
        while (i < self.available.items.len) {
            const conn = self.available.items[i];
            if (conn.ping()) {
                i += 1;
                continue;
            }
            conn.deinit();
            self.allocator.destroy(conn);
            for (self.connections.items, 0..) |item, j| {
                if (item == conn) {
                    _ = self.connections.swapRemove(j);
                    break;
                }
            }
            _ = self.available.swapRemove(i);
            self.current_connections -= 1;
        }
    }

    pub fn transaction(self: *ConnectionPool, comptime func: anytype, args: anytype) !void {
        const conn = try self.acquire();
        defer self.release(conn) catch {};

        try conn.begin();
        errdefer conn.rollback() catch |e| @panic(@errorName(e));

        try @call(.auto, func, .{conn} ++ args);
        try conn.commit();
    }
};

test "connection pool basic" {
    if (true) return error.SkipZigTest;
}
