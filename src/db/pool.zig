const std = @import("std");
const DB = @import("db.zig").DB;
const DBConfig = @import("config.zig").DBConfig;
const logger = @import("../core/logger.zig");
const io_instance = @import("../io_instance.zig");

/// 数据库连接池 synchronized by `std.Io.Mutex` / `std.Io.Condition`
/// (futex-backed via the active Io — same primitives the rest of the
/// framework uses; the pthread wrapper layer is gone as of v0.27.x).
///
/// Heap-allocated (init returns *ConnectionPool) so the caller holds one
/// stable pointer — no value-copy of synchronization state.
///
/// Cancellation contract: pool-internal locks use `lockUncancelable` /
/// `waitUncancelable`-grade primitives — an `Io` cancellation request must
/// never leave a pooled connection checked out or a waiter corrupted.
///
/// **Important:** `ping()` is never called while holding `mutex`. A blocking
/// MySQL/PG ping under the pool lock starves every other acquire and looks
/// like a thread-pool deadlock under concurrent login storms.
pub const ConnectionPool = struct {
    connections: std.ArrayList(*DB),
    available: std.ArrayList(*DB),
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
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
            .config = config,
            .allocator = allocator,
            .max_connections = max_connections,
            .current_connections = 0,
            .acquire_timeout_ms = 30000,
        };

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
        const io = io_instance.io;
        // Signal and join the background reaper if it was started.
        if (self.reaper_thread) |t| {
            self.reaper_stop.store(true, .monotonic);
            self.cond.broadcast(io);
            t.join();
            self.reaper_thread = null;
        }

        self.mutex.lockUncancelable(io);
        for (self.connections.items) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.connections.deinit(self.allocator);
        self.available.deinit(self.allocator);
        self.mutex.unlock(io);
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
            io_instance.io.sleep(std.Io.Duration.fromMilliseconds(@intCast(step_ms)), .awake) catch {};
        }
    }

    /// Pop one available connection or create one, without pinging under lock.
    /// `timeout` bounds the total wait (converted to an absolute deadline on
    /// the first entry so repeated wakeups cannot extend the window).
    fn takeCandidate(self: *ConnectionPool, timeout: std.Io.Timeout) !*DB {
        const io = io_instance.io;
        const deadline = timeout.toDeadline(io);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

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

            self.cond.waitTimeout(io, &self.mutex, deadline) catch |err| switch (err) {
                error.Timeout => return error.PoolTimeout,
                // A cancellation request must not tear down the waiting
                // acquire: re-enter the wait (uncancelable-critical section).
                error.Canceled => continue,
            };
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
        const timeout: std.Io.Timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(@intCast(self.acquire_timeout_ms)),
            .clock = .awake,
        } };

        while (true) {
            const candidate = try self.takeCandidate(timeout);

            // Ping OUTSIDE the pool mutex — a blocking driver ping must not
            // serialize every other worker thread.
            if (candidate.ping()) {
                // Mark checked-out before handing to the caller so a racing
                // release/double-path can detect ownership.
                candidate.checkOut();
                return candidate;
            }

            const io = io_instance.io;
            self.mutex.lockUncancelable(io);
            self.destroyLocked(candidate);
            self.cond.broadcast(io);
            self.mutex.unlock(io);
        }
    }

    pub fn release(self: *ConnectionPool, conn: *DB) !void {
        const io = io_instance.io;
        self.mutex.lockUncancelable(io);
        defer {
            // Wake all waiters. `signal` is enough for one returned conn in the
            // textbook sense, but under bursty acquire/release a single signal
            // + timedwait/spurious-wake interplay is harder to reason about.
            // Broadcast is cheap here (waiters re-check `available` under the
            // same mutex) and matches destroy/keepAlive. Note: condvar wake
            // policy does **not** by itself cause process Abort — that usually
            // means heap/magic panic or double-use of a driver connection.
            self.cond.broadcast(io);
            self.mutex.unlock(io);
        }

        // Double-release would append the same *DB twice → two acquire()s get
        // one MySQL/PG handle → libmysql abort / magic corruption under load.
        if (!conn.checked_out) {
            logger.getLogger().errFmt("ConnectionPool.release: connection not checked out (double release?)", .{});
            return error.AlreadyReleased;
        }
        for (self.available.items) |item| {
            if (item == conn) {
                logger.getLogger().errFmt("ConnectionPool.release: connection already in available list", .{});
                return error.AlreadyReleased;
            }
        }

        try self.available.append(self.allocator, conn);
        conn.checkIn();
    }

    pub fn keepAlive(self: *ConnectionPool) void {
        const io = io_instance.io;
        // Snapshot pointers under lock; ping outside; remove dead under lock.
        // Do NOT clear `available` for the duration of ping — that would block
        // every acquire until the reaper finishes.
        var snapshot = std.ArrayList(*DB).empty;
        defer snapshot.deinit(self.allocator);
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            snapshot.appendSlice(self.allocator, self.available.items) catch return;
        }

        var had_dead = false;
        for (snapshot.items) |conn| {
            if (conn.ping()) continue;
            had_dead = true;
            self.mutex.lockUncancelable(io);
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
            self.mutex.unlock(io);
        }
        if (had_dead) {
            self.mutex.lockUncancelable(io);
            self.cond.broadcast(io);
            self.mutex.unlock(io);
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

// ─── Concurrency stress regression (A1) ────────────────────────────────
//
// The historical segfault cluster (v0.12.x–v0.13.0) — struct-copy mutex
// corruption, discarded pthread_mutex_lock return values, 0xaa-fill reads in
// acquire/ping, double-release UAF — only reproduces under concurrent burst.
// These tests pin that surface on the always-available SQLite driver so they
// run in every `zig build test`, not just live-driver CI.

test "pool: burst stress — N threads hammer acquire/release on a small pool" {
    const a = std.testing.allocator;
    const threads = 8;
    const iters = 60;

    const pool = try ConnectionPool.init(a, DBConfig.sqliteMemory(), 2);
    defer pool.deinit();

    _ = try pool.acquire(); // leave only 1 conn contended for max contention
    // (released below; holding one shrinks the rotating pool to force waits)

    const Worker = struct {
        fn run(p: *ConnectionPool, n: usize) !void {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const conn = p.acquire() catch |e| switch (e) {
                    error.PoolTimeout => return error.TestUnexpectedResult, // waiters must be woken by release
                    else => |other| return other,
                };
                errdefer p.release(conn) catch {};
                // Reuse each conn ≥12 times across the run — the historical
                // "same connection reused ≥12 times then crash" trigger.
                var buf: [64]u8 = undefined;
                const sql = try std.fmt.bufPrintSentinel(&buf, "SELECT {d}", .{i}, 0);
                _ = try conn.exec(sql);
                try p.release(conn);
            }
        }
    };

    var ts: [threads]std.Thread = undefined;
    for (&ts) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ pool, iters });
    for (&ts) |t| t.join();
}

test "pool: concurrent transactions do not leak connections or wedge waiters" {
    const a = std.testing.allocator;
    const threads = 6;
    const iters = 40;

    // File-backed temp DB: WAL mode gives pool connections real concurrent
    // writer behavior (the production PG/MySQL analogue). Shared-cache
    // `:memory:` returns "table is locked" (SQLITE_LOCKED) on concurrent
    // write transactions regardless of busy_timeout — not a pool bug.
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    // tmpDir lives under .zig-cache/tmp/<random base64>; build the DB path
    // from cwd — sub_path is a valid path component as-is (url-safe base64).
    const db_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/pool_stress.db", .{&tmp_dir.sub_path});
    defer a.free(db_path);

    const pool = try ConnectionPool.init(a, DBConfig.sqlite(db_path), 3);
    defer pool.deinit();

    const TxWorker = struct {
        fn body(d: *DB, counter: usize) !void {
            var buf: [64]u8 = undefined;
            const sql = try std.fmt.bufPrintSentinel(
                &buf,
                "INSERT INTO stress_t (worker) VALUES ({d})",
                .{counter},
                0,
            );
            _ = try d.exec(sql);
        }
        fn run(p: *ConnectionPool, n: usize) !void {
            var i: usize = 0;
            while (i < n) : (i += 1) try p.transaction(body, .{i});
        }
    };

    const first = try pool.acquire();
    _ = try first.exec("CREATE TABLE stress_t (id INTEGER PRIMARY KEY, worker INTEGER)");
    try pool.release(first);

    var ts: [threads]std.Thread = undefined;
    for (&ts) |*t| t.* = try std.Thread.spawn(.{}, TxWorker.run, .{ pool, iters });
    for (&ts) |t| t.join();

    // All iterations committed through a 3-conn pool: no lost wakeups, no
    // wedged condvar (a PoolTimeout above would fail the test). Re-acquire
    // for verification — `first` was released above and the guard() correctly
    // rejects use-after-release.
    const again = try pool.acquire();
    defer pool.release(again) catch {};
    var r = try again.query("SELECT COUNT(*) FROM stress_t");
    defer r.deinit();
    try std.testing.expect(r.next());
    try std.testing.expectEqual(@as(i64, threads * iters), (try r.currentRow().?.getInt(0)).?);
}

test "pool: keepAlive with background reaper coexists with concurrent acquire" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const a = std.testing.allocator;

    const pool = try ConnectionPool.init(a, DBConfig.sqliteMemory(), 2);
    defer pool.deinit();
    try pool.startReaper(20); // aggressive interval to interleave with acquires

    const Worker = struct {
        fn run(p: *ConnectionPool) !void {
            var i: usize = 0;
            while (i < 30) : (i += 1) {
                const conn = try p.acquire();
                defer p.release(conn) catch {};
                _ = try conn.exec("SELECT 1");
            }
        }
    };
    var t1 = try std.Thread.spawn(.{}, Worker.run, .{pool});
    var t2 = try std.Thread.spawn(.{}, Worker.run, .{pool});
    t1.join();
    t2.join();

    // startReaper is idempotent; a second call must not spawn a thread.
    try pool.startReaper(20);
}

test "pool: double release is rejected instead of corrupting the available list" {
    const a = std.testing.allocator;
    const pool = try ConnectionPool.init(a, DBConfig.sqliteMemory(), 2);
    defer pool.deinit();

    const conn = try pool.acquire();
    try pool.release(conn);
    try std.testing.expectError(error.AlreadyReleased, pool.release(conn));
}
