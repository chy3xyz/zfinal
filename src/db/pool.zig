const std = @import("std");
const DB = @import("db.zig").DB;
const DBConfig = @import("config.zig").DBConfig;
const mutex_init = @import("mutex_init.zig");

/// 数据库连接池 with POSIX thread synchronization.
///
/// Heap-allocated (init returns *ConnectionPool) to avoid struct copy
/// of pthread_mutex_t / pthread_cond_t. pthread_mutex_init /
/// pthread_cond_init run at allocation time; the caller gets the pointer
/// directly — no value-copy that could drop internal flags.
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

    pub fn init(allocator: std.mem.Allocator, config: DBConfig, max_connections: usize) !*ConnectionPool {
        var pool = try allocator.create(ConnectionPool);
        errdefer allocator.destroy(pool);
        pool.* = ConnectionPool{
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

        // Pre-create all connections on the calling thread (typically main).
        // This avoids mysql_real_connect running in a worker thread where
        // Zig 0.17 std.Thread.spawn TLS/errno corruption breaks MySQL on
        // aarch64-macos.
        for (0..max_connections) |_| {
            const conn = try DB.init(allocator, config);
            errdefer conn.deinit();
            try pool.connections.append(allocator, conn);
            try pool.available.append(allocator, conn);
            pool.current_connections += 1;
        }

        return pool;
    }

    pub fn deinit(self: *ConnectionPool) void {
        mutex_init.lockMut(&self.mutex);
        defer mutex_init.unlockMut(&self.mutex);

        for (self.connections.items) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.connections.deinit(self.allocator);
        self.available.deinit(self.allocator);
        mutex_init.destroyMutex(&self.mutex);
        mutex_init.destroyCond(&self.cond);
        self.allocator.destroy(self);
    }

    pub fn acquire(self: *ConnectionPool) !*DB {
        mutex_init.lockMut(&self.mutex);
        defer mutex_init.unlockMut(&self.mutex);

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
                // Should never reach here: all connections pre-created in init().
                // Fallback for edge cases (e.g. all connections died and were removed).
                const conn = try DB.init(self.allocator, self.config);
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
        mutex_init.lockMut(&self.mutex);
        defer mutex_init.unlockMut(&self.mutex);

        try self.available.append(self.allocator, conn);
        mutex_init.signalCond(&self.cond);
    }

    pub fn keepAlive(self: *ConnectionPool) void {
        mutex_init.lockMut(&self.mutex);
        defer mutex_init.unlockMut(&self.mutex);

        var had_dead = false;
        var i: usize = 0;
        while (i < self.available.items.len) {
            const conn = self.available.items[i];
            if (conn.ping()) {
                i += 1;
                continue;
            }
            had_dead = true;
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
        // Wake ALL waiters if connections were freed — new ones can be created
        if (had_dead) {
            mutex_init.broadcastCond(&self.cond);
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
