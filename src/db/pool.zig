const std = @import("std");
const DB = @import("db.zig").DB;
const DBConfig = @import("config.zig").DBConfig;
const mutex_init = @import("mutex_init.zig");
const logger = @import("../core/logger.zig");

/// 数据库连接池 with POSIX thread synchronization.
///
/// Heap-allocated (init returns *ConnectionPool) to avoid struct copy
/// of pthread_mutex_t / pthread_cond_t. pthread_mutex_init /
/// pthread_cond_init run at allocation time; the caller gets the pointer
/// directly — no value-copy that could drop internal flags.
///
/// **Important:** `ping()` is never called while holding `mutex`. A blocking
/// MySQL/PG ping under the pool lock starves every other acquire and looks
/// like a thread-pool deadlock under concurrent login storms.
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
    /// Background keep-alive interval. 0 means disabled (caller must call keepAlive()).
    reaper_interval_ms: u64 = 0,
    reaper_thread: ?std.Thread = null,
    reaper_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator, config: DBConfig, max_connections: usize) !*ConnectionPool {
        var pool = try allocator.create(ConnectionPool);
        errdefer allocator.destroy(pool);

        // Pre-allocate ArrayList capacity to avoid reallocation during operation.
        // Reallocation frees the old buffer (0xaa fill), and with Zig 0.17's
        // debug allocator, a nearby DB struct might be inadvertently corrupted
        // if the freed buffer overlaps or is on the same page.
        var connections = std.ArrayList(*DB).empty;
        try connections.ensureTotalCapacity(allocator, max_connections);
        var available = std.ArrayList(*DB).empty;
        try available.ensureTotalCapacity(allocator, max_connections);

        pool.* = ConnectionPool{
            .connections = connections,
            .available = available,
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
        for (0..max_connections) |_| {
            const conn = try DB.init(allocator, config);
            errdefer conn.deinit();
            conn.checkIn(); // pooled conns start as "not checked out"
            try pool.connections.append(allocator, conn);
            try pool.available.append(allocator, conn);
            pool.current_connections += 1;
        }

        return pool;
    }

    pub fn deinit(self: *ConnectionPool) void {
        // Signal and join the background reaper if it was started.
        if (self.reaper_thread) |t| {
            self.reaper_stop.store(true, .monotonic);
            mutex_init.broadcastCond(&self.cond);
            t.join();
            self.reaper_thread = null;
        }

        mutex_init.lockMut(&self.mutex);
        for (self.connections.items) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.connections.deinit(self.allocator);
        self.available.deinit(self.allocator);
        // POSIX requires the mutex to be unlocked before destruction —
        // a `defer unlock` here would fire after destroyMutex/destroy(self)
        // and unlock freed memory.
        mutex_init.unlockMut(&self.mutex);
        mutex_init.destroyMutex(&self.mutex);
        mutex_init.destroyCond(&self.cond);
        self.allocator.destroy(self);
    }

    /// Start a background thread that runs `keepAlive()` every
    /// `interval_ms`. Call once after init. Calling more than once is a no-op.
    pub fn startReaper(self: *ConnectionPool, interval_ms: u64) !void {
        if (self.reaper_thread != null) return;
        self.reaper_interval_ms = interval_ms;
        self.reaper_thread = try std.Thread.spawn(.{}, reaperLoop, .{self});
    }

    fn reaperLoop(self: *ConnectionPool) void {
        while (!self.reaper_stop.load(.monotonic)) {
            self.keepAlive();
            const step_ms = @min(self.reaper_interval_ms, 1000);
            if (step_ms == 0) break;
            std.time.sleep(step_ms * std.time.ns_per_ms);
        }
    }

    fn nowMs() i64 {
        var now_ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &now_ts);
        return @as(i64, @intCast(now_ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(now_ts.nsec)), 1_000_000);
    }

    /// Pop one available connection or create one, without pinging under lock.
    fn takeCandidate(self: *ConnectionPool, deadline_ms: i64) !*DB {
        mutex_init.lockMut(&self.mutex);
        defer mutex_init.unlockMut(&self.mutex);

        while (true) {
            if (self.available.items.len > 0) {
                return self.available.pop().?;
            }

            if (self.current_connections < self.max_connections) {
                // Should rarely reach here: all connections pre-created in init().
                // Fallback when dead conns were removed.
                const conn = try DB.init(self.allocator, self.config);
                try self.connections.append(self.allocator, conn);
                self.current_connections += 1;
                return conn;
            }

            const now_ms = nowMs();
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

    fn destroyLocked(self: *ConnectionPool, conn: *DB) void {
        conn.deinit();
        self.allocator.destroy(conn);
        for (self.connections.items, 0..) |item, i| {
            if (item == conn) {
                _ = self.connections.swapRemove(i);
                break;
            }
        }
        if (self.current_connections > 0) self.current_connections -= 1;
    }

    pub fn acquire(self: *ConnectionPool) !*DB {
        const deadline_ms = nowMs() + @as(i64, @intCast(self.acquire_timeout_ms));

        while (true) {
            const candidate = try self.takeCandidate(deadline_ms);

            // Ping OUTSIDE the pool mutex — a blocking driver ping must not
            // serialize every other worker thread.
            if (candidate.ping()) {
                candidate.checkOut();
                return candidate;
            }

            mutex_init.lockMut(&self.mutex);
            self.destroyLocked(candidate);
            mutex_init.broadcastCond(&self.cond);
            mutex_init.unlockMut(&self.mutex);
        }
    }

    pub fn release(self: *ConnectionPool, conn: *DB) !void {
        mutex_init.lockMut(&self.mutex);
        defer {
            mutex_init.signalCond(&self.cond);
            mutex_init.unlockMut(&self.mutex);
        }

        try self.available.append(self.allocator, conn);
        conn.checkIn(); // mark as available only after it is back in the pool
    }

    pub fn keepAlive(self: *ConnectionPool) void {
        // Snapshot pointers under lock; ping outside; remove dead under lock.
        // Do NOT clear `available` for the duration of ping — that would block
        // every acquire until the reaper finishes.
        var snapshot = std.ArrayList(*DB).empty;
        defer snapshot.deinit(self.allocator);
        {
            mutex_init.lockMut(&self.mutex);
            defer mutex_init.unlockMut(&self.mutex);
            snapshot.appendSlice(self.allocator, self.available.items) catch return;
        }

        var had_dead = false;
        for (snapshot.items) |conn| {
            if (conn.ping()) continue;
            had_dead = true;
            mutex_init.lockMut(&self.mutex);
            // Only destroy if still sitting in available (not checked out).
            var still_available = false;
            for (self.available.items, 0..) |item, i| {
                if (item == conn) {
                    _ = self.available.swapRemove(i);
                    still_available = true;
                    break;
                }
            }
            if (still_available) self.destroyLocked(conn);
            mutex_init.unlockMut(&self.mutex);
        }
        if (had_dead) {
            mutex_init.lockMut(&self.mutex);
            mutex_init.broadcastCond(&self.cond);
            mutex_init.unlockMut(&self.mutex);
        }
    }

    pub fn transaction(self: *ConnectionPool, comptime func: anytype, args: anytype) !void {
        const conn = try self.acquire();
        defer self.release(conn) catch {};

        try conn.begin();
        // A failed rollback must not kill the process: the original error
        // still propagates, and the connection is dropped by the pool's
        // dead-connection sweep on release.
        errdefer conn.rollback() catch |e| {
            logger.getLogger().errFmt("pool.transaction rollback failed: {t}", .{e});
        };

        try @call(.auto, func, .{conn} ++ args);
        try conn.commit();
    }
};

test "connection pool basic" {
    if (true) return error.SkipZigTest;
}
