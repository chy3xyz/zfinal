//! Durable outbox over `zfinal.DB` (SQLite-compatible DDL).
//! Use inside `db.transaction` with domain writes for at-least-once delivery.
//!
//! ```zig
//! var box = try zfinal.DbOutbox.init(allocator, db);
//! defer box.deinit();
//! try db.transaction(null, struct {
//!     fn body(d: *zfinal.DB) !void {
//!         try d.exec("INSERT INTO orders …");
//!         try box.port().append(a, "order.placed", payload, idem);
//!     }
//! }.body);
//! // worker:
//! const batch = try box.fetchUnpublished(a, 100);
//! defer box.freeBatch(a, batch);
//! for (batch) |row| { try bus.publish(row.event_type, row.payload); try box.markPublished(row.id); }
//! ```

const std = @import("std");
const DB = @import("../db/db.zig").DB;
const SqlParam = @import("../db/sql_param.zig").SqlParam;
const Outbox = @import("outbox.zig").Outbox;
const TimeKit = @import("../kit/time_kit.zig").TimeKit;

pub const OutboxRow = struct {
    id: i64,
    event_type: []const u8,
    payload: []const u8,
    idempotency_key: []const u8,
    created_at_ms: i64,

    pub fn deinit(self: OutboxRow, allocator: std.mem.Allocator) void {
        allocator.free(self.event_type);
        allocator.free(self.payload);
        allocator.free(self.idempotency_key);
    }
};

pub const DbOutbox = struct {
    allocator: std.mem.Allocator,
    db: *DB,

    pub fn init(allocator: std.mem.Allocator, db: *DB) !DbOutbox {
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS zfinal_outbox (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  event_type TEXT NOT NULL,
            \\  payload TEXT NOT NULL,
            \\  idempotency_key TEXT NOT NULL UNIQUE,
            \\  created_at_ms INTEGER NOT NULL,
            \\  published_at_ms INTEGER
            \\)
        );
        return .{ .allocator = allocator, .db = db };
    }

    pub fn deinit(self: *DbOutbox) void {
        self.* = undefined;
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
        // INSERT OR IGNORE → idempotent under UNIQUE(idempotency_key)
        const params = [_]SqlParam{
            .{ .text = event_type },
            .{ .text = payload },
            .{ .text = idempotency_key },
            .{ .int = now },
        };
        try self.db.execParams(
            "INSERT OR IGNORE INTO zfinal_outbox (event_type, payload, idempotency_key, created_at_ms) VALUES (?, ?, ?, ?)",
            &params,
        );
    }

    const vtable = Outbox.VTable{ .append = appendImpl };

    /// Unpublished rows oldest-first. Caller frees via `freeBatch`.
    pub fn fetchUnpublished(self: *DbOutbox, allocator: std.mem.Allocator, limit: usize) ![]OutboxRow {
        var sql_buf: [192]u8 = undefined;
        const sql = try std.fmt.bufPrint(
            &sql_buf,
            "SELECT id, event_type, payload, idempotency_key, created_at_ms FROM zfinal_outbox WHERE published_at_ms IS NULL ORDER BY id ASC LIMIT {d}",
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
            try list.append(allocator, .{
                .id = id,
                .event_type = try allocator.dupe(u8, et),
                .payload = try allocator.dupe(u8, pl),
                .idempotency_key = try allocator.dupe(u8, ik),
                .created_at_ms = created,
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

    pub fn unpublishedCount(self: *DbOutbox) !usize {
        var rs = try self.db.query("SELECT COUNT(*) FROM zfinal_outbox WHERE published_at_ms IS NULL");
        defer rs.deinit();
        if (!rs.next()) return 0;
        const n = try rs.currentRowMut().?.getInt(0);
        return @intCast(n orelse 0);
    }
};

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
