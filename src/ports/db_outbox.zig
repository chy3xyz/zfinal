//! Durable outbox over `zfinal.DB` (SQLite / PostgreSQL / MySQL DDL).
//! Use inside the same transaction as domain writes for at-least-once delivery.
//!
//! ```zig
//! var box = try zfinal.DbOutbox.init(allocator, db);
//! defer box.deinit();
//! try db.begin();
//! try d.exec("INSERT INTO orders …");
//! try box.port().append(a, "order.placed", payload, idem);
//! try db.commit();
//! // worker tick:
//! const st = try box.drainOnce(a, bus, .{});
//! ```

const std = @import("std");
const DB = @import("../db/db.zig").DB;
const SqlParam = @import("../db/sql_param.zig").SqlParam;
const Outbox = @import("outbox.zig").Outbox;
const Bus = @import("../bus/bus.zig").Bus;
const TimeKit = @import("../kit/time_kit.zig").TimeKit;

pub const OutboxDialect = enum { sqlite, postgres, mysql };

pub const OutboxRow = struct {
    id: i64,
    event_type: []const u8,
    payload: []const u8,
    idempotency_key: []const u8,
    created_at_ms: i64,
    attempts: i64 = 0,

    pub fn deinit(self: OutboxRow, allocator: std.mem.Allocator) void {
        allocator.free(self.event_type);
        allocator.free(self.payload);
        allocator.free(self.idempotency_key);
    }
};

pub const DrainOpts = struct {
    batch_limit: usize = 100,
    max_attempts: u32 = 8,
};

pub const DrainStats = struct {
    published: usize = 0,
    failed: usize = 0,
    dead: usize = 0,
};

pub const DbOutbox = struct {
    allocator: std.mem.Allocator,
    db: *DB,
    dialect: OutboxDialect,

    pub fn init(allocator: std.mem.Allocator, db: *DB) !DbOutbox {
        const d = dialectOf(db);
        try db.exec(ddlCreate(d));
        try migrateColumns(db, d);
        return .{ .allocator = allocator, .db = db, .dialect = d };
    }

    pub fn deinit(self: *DbOutbox) void {
        self.* = undefined;
    }

    pub fn dialectOf(db: *DB) OutboxDialect {
        return switch (db.driver) {
            .sqlite => .sqlite,
            .postgres => .postgres,
            .mysql => .mysql,
        };
    }

    /// CREATE TABLE DDL for the active dialect (exported for unit tests).
    pub fn ddlCreate(d: OutboxDialect) [:0]const u8 {
        return switch (d) {
            .sqlite =>
            \\CREATE TABLE IF NOT EXISTS zfinal_outbox (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  event_type TEXT NOT NULL,
            \\  payload TEXT NOT NULL,
            \\  idempotency_key TEXT NOT NULL UNIQUE,
            \\  created_at_ms INTEGER NOT NULL,
            \\  published_at_ms INTEGER,
            \\  attempts INTEGER NOT NULL DEFAULT 0,
            \\  last_error TEXT,
            \\  dead_at_ms INTEGER
            \\)
            ,
            .postgres =>
            \\CREATE TABLE IF NOT EXISTS zfinal_outbox (
            \\  id BIGSERIAL PRIMARY KEY,
            \\  event_type TEXT NOT NULL,
            \\  payload TEXT NOT NULL,
            \\  idempotency_key TEXT NOT NULL UNIQUE,
            \\  created_at_ms BIGINT NOT NULL,
            \\  published_at_ms BIGINT,
            \\  attempts INTEGER NOT NULL DEFAULT 0,
            \\  last_error TEXT,
            \\  dead_at_ms BIGINT
            \\)
            ,
            .mysql =>
            \\CREATE TABLE IF NOT EXISTS zfinal_outbox (
            \\  id BIGINT AUTO_INCREMENT PRIMARY KEY,
            \\  event_type TEXT NOT NULL,
            \\  payload TEXT NOT NULL,
            \\  idempotency_key VARCHAR(255) NOT NULL UNIQUE,
            \\  created_at_ms BIGINT NOT NULL,
            \\  published_at_ms BIGINT NULL,
            \\  attempts INT NOT NULL DEFAULT 0,
            \\  last_error TEXT,
            \\  dead_at_ms BIGINT NULL
            \\) ENGINE=InnoDB
            ,
        };
    }

    pub fn insertSql(d: OutboxDialect) [:0]const u8 {
        return switch (d) {
            .sqlite => "INSERT OR IGNORE INTO zfinal_outbox (event_type, payload, idempotency_key, created_at_ms) VALUES (?, ?, ?, ?)",
            .postgres => "INSERT INTO zfinal_outbox (event_type, payload, idempotency_key, created_at_ms) VALUES (?, ?, ?, ?) ON CONFLICT (idempotency_key) DO NOTHING",
            .mysql => "INSERT IGNORE INTO zfinal_outbox (event_type, payload, idempotency_key, created_at_ms) VALUES (?, ?, ?, ?)",
        };
    }

    fn migrateColumns(db: *DB, d: OutboxDialect) !void {
        // Fresh CREATE already has columns; ALTER is for older installs only.
        if (d != .sqlite) return;
        var rs = db.query("PRAGMA table_info(zfinal_outbox)") catch return;
        defer rs.deinit();
        var has_attempts = false;
        var has_last_error = false;
        var has_dead = false;
        while (rs.next()) {
            const row = rs.currentRowMut() orelse continue;
            const name = row.getText(1) orelse continue;
            if (std.mem.eql(u8, name, "attempts")) has_attempts = true;
            if (std.mem.eql(u8, name, "last_error")) has_last_error = true;
            if (std.mem.eql(u8, name, "dead_at_ms")) has_dead = true;
        }
        if (!has_attempts) db.exec("ALTER TABLE zfinal_outbox ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0") catch {};
        if (!has_last_error) db.exec("ALTER TABLE zfinal_outbox ADD COLUMN last_error TEXT") catch {};
        if (!has_dead) db.exec("ALTER TABLE zfinal_outbox ADD COLUMN dead_at_ms INTEGER") catch {};
    }

    pub fn port(self: *DbOutbox) Outbox {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn appendImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        event_type: []const u8,
        payload: []const u8,
        idempotency_key: []const u8,
    ) anyerror!void {
        _ = allocator;
        const self: *DbOutbox = @ptrCast(@alignCast(ptr));
        const now = TimeKit.nowMillis();
        const params = [_]SqlParam{
            .{ .text = event_type },
            .{ .text = payload },
            .{ .text = idempotency_key },
            .{ .int = now },
        };
        try self.db.execParams(insertSql(self.dialect), &params);
    }

    const vtable = Outbox.VTable{ .append = appendImpl };

    /// Unpublished, non-dead rows oldest-first. Caller frees via `freeBatch`.
    pub fn fetchUnpublished(self: *DbOutbox, allocator: std.mem.Allocator, limit: usize) ![]OutboxRow {
        var sql_buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(
            &sql_buf,
            "SELECT id, event_type, payload, idempotency_key, created_at_ms, attempts FROM zfinal_outbox WHERE published_at_ms IS NULL AND dead_at_ms IS NULL ORDER BY id ASC LIMIT {d}",
            .{limit},
        );
        const sql_z = try allocator.allocSentinel(u8, sql.len, 0);
        defer allocator.free(sql_z);
        @memcpy(sql_z[0..sql.len], sql);

        var rs = try self.db.query(sql_z);
        defer rs.deinit();

        var list: std.ArrayList(OutboxRow) = .empty;
        errdefer {
            for (list.items) |r| r.deinit(allocator);
            list.deinit(allocator);
        }
        while (rs.next()) {
            const row = rs.currentRowMut() orelse continue;
            const id = (try row.getInt(0)) orelse continue;
            const et = row.getText(1) orelse "";
            const pl = row.getText(2) orelse "";
            const ik = row.getText(3) orelse "";
            const created = (try row.getInt(4)) orelse 0;
            const attempts = (try row.getInt(5)) orelse 0;
            try list.append(allocator, .{
                .id = id,
                .event_type = try allocator.dupe(u8, et),
                .payload = try allocator.dupe(u8, pl),
                .idempotency_key = try allocator.dupe(u8, ik),
                .created_at_ms = created,
                .attempts = attempts,
            });
        }
        return try list.toOwnedSlice(allocator);
    }

    pub fn freeBatch(allocator: std.mem.Allocator, batch: []OutboxRow) void {
        for (batch) |r| r.deinit(allocator);
        allocator.free(batch);
    }

    pub fn markPublished(self: *DbOutbox, id: i64) !void {
        const now = TimeKit.nowMillis();
        const params = [_]SqlParam{ .{ .int = now }, .{ .int = id } };
        try self.db.execParams(
            "UPDATE zfinal_outbox SET published_at_ms = ? WHERE id = ? AND published_at_ms IS NULL",
            &params,
        );
    }

    /// Increment attempts; mark dead when `attempts >= max_attempts`.
    pub fn markFailed(self: *DbOutbox, id: i64, err_msg: []const u8, max_attempts: u32) !bool {
        const now = TimeKit.nowMillis();
        const params = [_]SqlParam{
            .{ .text = err_msg },
            .{ .int = id },
        };
        try self.db.execParams(
            "UPDATE zfinal_outbox SET attempts = attempts + 1, last_error = ? WHERE id = ? AND published_at_ms IS NULL AND dead_at_ms IS NULL",
            &params,
        );
        var rs = try self.db.queryParams(
            "SELECT attempts FROM zfinal_outbox WHERE id = ?",
            &.{.{ .int = id }},
        );
        defer rs.deinit();
        if (!rs.next()) return false;
        const attempts: u32 = @intCast((try rs.currentRowMut().?.getInt(0)) orelse 0);
        if (attempts >= max_attempts) {
            try self.db.execParams(
                "UPDATE zfinal_outbox SET dead_at_ms = ? WHERE id = ? AND dead_at_ms IS NULL",
                &.{ .{ .int = now }, .{ .int = id } },
            );
            return true;
        }
        return false;
    }

    pub fn unpublishedCount(self: *DbOutbox) !usize {
        var rs = try self.db.query("SELECT COUNT(*) FROM zfinal_outbox WHERE published_at_ms IS NULL AND dead_at_ms IS NULL");
        defer rs.deinit();
        if (!rs.next()) return 0;
        const n = try rs.currentRowMut().?.getInt(0);
        return @intCast(n orelse 0);
    }

    pub fn deadCount(self: *DbOutbox) !usize {
        var rs = try self.db.query("SELECT COUNT(*) FROM zfinal_outbox WHERE dead_at_ms IS NOT NULL");
        defer rs.deinit();
        if (!rs.next()) return 0;
        const n = try rs.currentRowMut().?.getInt(0);
        return @intCast(n orelse 0);
    }

    /// Poll → `bus.publish` → markPublished; on error markFailed / dead-letter.
    pub fn drainOnce(self: *DbOutbox, allocator: std.mem.Allocator, bus: Bus, opts: DrainOpts) !DrainStats {
        const batch = try self.fetchUnpublished(allocator, opts.batch_limit);
        defer freeBatch(allocator, batch);
        var st: DrainStats = .{};
        for (batch) |row| {
            bus.publish(row.event_type, row.payload) catch |err| {
                var msg_buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "{t}", .{err}) catch "publish failed";
                const dead = try self.markFailed(row.id, msg, opts.max_attempts);
                st.failed += 1;
                if (dead) st.dead += 1;
                continue;
            };
            try self.markPublished(row.id);
            st.published += 1;
        }
        return st;
    }

    pub fn toPrometheusFormat(self: *DbOutbox, allocator: std.mem.Allocator) ![]u8 {
        const open_n = try self.unpublishedCount();
        const dead_n = try self.deadCount();
        return try std.fmt.allocPrint(allocator,
            \\# HELP zfinal_outbox_unpublished Pending outbox rows.
            \\# TYPE zfinal_outbox_unpublished gauge
            \\zfinal_outbox_unpublished {d}
            \\# HELP zfinal_outbox_dead Dead-lettered outbox rows.
            \\# TYPE zfinal_outbox_dead gauge
            \\zfinal_outbox_dead {d}
            \\
        , .{ open_n, dead_n });
    }
};

test "DbOutbox dialect DDL and insert SQL" {
    try std.testing.expect(std.mem.indexOf(u8, DbOutbox.ddlCreate(.sqlite), "AUTOINCREMENT") != null);
    try std.testing.expect(std.mem.indexOf(u8, DbOutbox.ddlCreate(.postgres), "BIGSERIAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, DbOutbox.ddlCreate(.mysql), "AUTO_INCREMENT") != null);
    try std.testing.expect(std.mem.indexOf(u8, DbOutbox.insertSql(.postgres), "ON CONFLICT") != null);
    try std.testing.expect(std.mem.indexOf(u8, DbOutbox.insertSql(.mysql), "INSERT IGNORE") != null);
}

test "DbOutbox append idempotent and fetch/mark" {
    const a = std.testing.allocator;
    const DBConfig = @import("../db/config.zig").DBConfig;
    var db = try DB.init(a, DBConfig.sqliteMemory());
    defer db.destroy();

    var box = try DbOutbox.init(a, db);
    defer box.deinit();
    const p = box.port();

    try p.append(a, "order.placed", "{\"id\":1}", "idem-1");
    try p.append(a, "order.placed", "{\"id\":1}", "idem-1");
    try std.testing.expectEqual(@as(usize, 1), try box.unpublishedCount());

    const batch = try box.fetchUnpublished(a, 10);
    defer DbOutbox.freeBatch(a, batch);
    try std.testing.expectEqual(@as(usize, 1), batch.len);
    try std.testing.expectEqualStrings("order.placed", batch[0].event_type);

    try box.markPublished(batch[0].id);
    try std.testing.expectEqual(@as(usize, 0), try box.unpublishedCount());
}

test "DbOutbox works inside transaction with domain write" {
    const a = std.testing.allocator;
    const DBConfig = @import("../db/config.zig").DBConfig;
    var db = try DB.init(a, DBConfig.sqliteMemory());
    defer db.destroy();
    try db.exec("CREATE TABLE orders (id TEXT PRIMARY KEY, body TEXT)");

    var box = try DbOutbox.init(a, db);
    defer box.deinit();

    try db.begin();
    try db.execParams("INSERT INTO orders (id, body) VALUES (?, ?)", &.{
        .{ .text = "o1" },
        .{ .text = "{}" },
    });
    try box.port().append(a, "order.placed", "{}", "o1-idem");
    try db.commit();

    try std.testing.expectEqual(@as(usize, 1), try box.unpublishedCount());
    var rs = try db.query("SELECT COUNT(*) FROM orders");
    defer rs.deinit();
    try std.testing.expect(rs.next());
    try std.testing.expectEqual(@as(i64, 1), (try rs.currentRowMut().?.getInt(0)).?);
}

test "DbOutbox drainOnce publishes via MemoryBus" {
    const a = std.testing.allocator;
    const DBConfig = @import("../db/config.zig").DBConfig;
    const MemoryBus = @import("../bus/memory_bus.zig").MemoryBus;

    var db = try DB.init(a, DBConfig.sqliteMemory());
    defer db.destroy();
    var box = try DbOutbox.init(a, db);
    defer box.deinit();
    var bus_impl = MemoryBus.init(a);
    defer bus_impl.deinit();
    const mb = try bus_impl.queue.subscribe("order.placed");
    defer {
        mb.deinit();
        a.destroy(mb);
    }

    try box.port().append(a, "order.placed", "{\"ok\":1}", "d1");
    const st = try box.drainOnce(a, bus_impl.port(), .{});
    try std.testing.expectEqual(@as(usize, 1), st.published);
    try std.testing.expectEqual(@as(usize, 0), try box.unpublishedCount());

    var msg = mb.tryPop() orelse return error.TestUnexpectedResult;
    defer msg.deinit(a);
    try std.testing.expectEqualStrings("{\"ok\":1}", msg.data);

    const prom = try box.toPrometheusFormat(a);
    defer a.free(prom);
    try std.testing.expect(std.mem.indexOf(u8, prom, "zfinal_outbox_unpublished 0") != null);
}

test "DbOutbox markFailed dead-letters after max_attempts" {
    const a = std.testing.allocator;
    const DBConfig = @import("../db/config.zig").DBConfig;
    var db = try DB.init(a, DBConfig.sqliteMemory());
    defer db.destroy();
    var box = try DbOutbox.init(a, db);
    defer box.deinit();
    try box.port().append(a, "t", "{}", "fail-1");
    const batch = try box.fetchUnpublished(a, 1);
    defer DbOutbox.freeBatch(a, batch);
    const id = batch[0].id;

    try std.testing.expect(!(try box.markFailed(id, "e1", 2)));
    try std.testing.expect(try box.markFailed(id, "e2", 2));
    try std.testing.expectEqual(@as(usize, 0), try box.unpublishedCount());
    try std.testing.expectEqual(@as(usize, 1), try box.deadCount());
}

fn liveEnv(allocator: std.mem.Allocator, name: [:0]const u8, default: []const u8) ?[]const u8 {
    const raw = std.c.getenv(name.ptr);
    if (raw) |ptr| return allocator.dupe(u8, std.mem.sliceTo(ptr, 0)) catch return null;
    if (default.len == 0) return null;
    return allocator.dupe(u8, default) catch return null;
}

fn tryOpenLivePg(allocator: std.mem.Allocator) !?*DB {
    const build_opts = @import("build_options");
    if (!build_opts.enable_pg) return null;
    const pwd = liveEnv(allocator, "ZF_PG_PASSWORD", "") orelse return null;
    defer allocator.free(pwd);
    const host = liveEnv(allocator, "ZF_PG_HOST", "localhost") orelse return null;
    defer allocator.free(host);
    const port_str = liveEnv(allocator, "ZF_PG_PORT", "5432") orelse return null;
    defer allocator.free(port_str);
    const port = std.fmt.parseInt(u16, port_str, 10) catch @as(u16, 5432);
    const user = liveEnv(allocator, "ZF_PG_USER", "postgres") orelse return null;
    defer allocator.free(user);
    const db_name = liveEnv(allocator, "ZF_PG_DATABASE", "zfinal_test") orelse return null;
    defer allocator.free(db_name);
    return DB.init(allocator, .{
        .db_type = .postgres,
        .host = host,
        .port = port,
        .database = db_name,
        .username = user,
        .password = pwd,
    }) catch null;
}

fn tryOpenLiveMy(allocator: std.mem.Allocator) !?*DB {
    const build_opts = @import("build_options");
    if (!build_opts.enable_mysql) return null;
    const pwd = liveEnv(allocator, "ZF_MY_PASSWORD", "") orelse return null;
    defer allocator.free(pwd);
    const host = liveEnv(allocator, "ZF_MY_HOST", "localhost") orelse return null;
    defer allocator.free(host);
    const port_str = liveEnv(allocator, "ZF_MY_PORT", "3306") orelse return null;
    defer allocator.free(port_str);
    const port = std.fmt.parseInt(u16, port_str, 10) catch @as(u16, 3306);
    const user = liveEnv(allocator, "ZF_MY_USER", "root") orelse return null;
    defer allocator.free(user);
    const db_name = liveEnv(allocator, "ZF_MY_DATABASE", "zfinal_test") orelse return null;
    defer allocator.free(db_name);
    return DB.init(allocator, .{
        .db_type = .mysql,
        .host = host,
        .port = port,
        .database = db_name,
        .username = user,
        .password = pwd,
    }) catch null;
}

fn liveDrainRoundtrip(a: std.mem.Allocator, db: *DB, dialect: OutboxDialect) !void {
    // Isolate from other suites on shared live DBs.
    db.exec("DROP TABLE IF EXISTS zfinal_outbox") catch {};
    var box = try DbOutbox.init(a, db);
    defer box.deinit();
    try std.testing.expectEqual(dialect, box.dialect);

    const MemoryBus = @import("../bus/memory_bus.zig").MemoryBus;
    var bus_impl = MemoryBus.init(a);
    defer bus_impl.deinit();
    const mb = try bus_impl.queue.subscribe("order.live");
    defer {
        mb.deinit();
        a.destroy(mb);
    }

    const idem = try std.fmt.allocPrint(a, "live-{s}-{d}", .{ @tagName(dialect), TimeKit.nowMillis() });
    defer a.free(idem);
    try box.port().append(a, "order.live", "{\"live\":1}", idem);
    try box.port().append(a, "order.live", "{\"live\":1}", idem); // idempotent
    try std.testing.expectEqual(@as(usize, 1), try box.unpublishedCount());

    const st = try box.drainOnce(a, bus_impl.port(), .{});
    try std.testing.expectEqual(@as(usize, 1), st.published);
    try std.testing.expectEqual(@as(usize, 0), try box.unpublishedCount());
    var msg = mb.tryPop() orelse return error.TestUnexpectedResult;
    defer msg.deinit(a);
    try std.testing.expectEqualStrings("{\"live\":1}", msg.data);
}

test "DbOutbox live drainOnce on PostgreSQL" {
    const a = std.testing.allocator;
    var db = (try tryOpenLivePg(a)) orelse return error.SkipZigTest;
    defer db.destroy();
    try liveDrainRoundtrip(a, db, .postgres);
}

test "DbOutbox live drainOnce on MySQL" {
    const a = std.testing.allocator;
    var db = (try tryOpenLiveMy(a)) orelse return error.SkipZigTest;
    defer db.destroy();
    try liveDrainRoundtrip(a, db, .mysql);
}
