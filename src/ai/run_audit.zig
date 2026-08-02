//! Durable-ish AI run audit trail (in-memory ring + optional SQLite + JSON file).
//! Complements ring `AgentAuditLog` (tool-level) with one row per agent /
//! workflow / trigger run. Attach via `Agent.run_audit` / `Workflow.run_audit`.
//! Call `attachDb` to dual-write into `ai_run_audit` (survives restarts).

const std = @import("std");
const time_util = @import("time_util.zig");
const DB = @import("../db/db.zig").DB;
const SqlParam = @import("../db/sql_param.zig").SqlParam;

pub const RunKind = enum { workflow, agent, trigger, approval };

pub const RunAuditEntry = struct {
    run_id: []const u8,
    kind: RunKind,
    status: []const u8,
    tenant_id: ?i64 = null,
    steps: usize = 0,
    duration_ms: i64 = 0,
    created_at_ms: i64 = 0,
};

pub const RunAuditStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    entries: []RunAuditEntry,
    next: usize = 0,
    count: usize = 0,
    /// Optional SQLite/any DB dual-write target.
    db: ?*DB = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, capacity: usize) !RunAuditStore {
        const cap = if (capacity == 0) 256 else capacity;
        const entries = try allocator.alloc(RunAuditEntry, cap);
        for (entries) |*e| e.* = .{ .run_id = "", .kind = .agent, .status = "" };
        return .{
            .allocator = allocator,
            .io = io,
            .mutex = .init,
            .entries = entries,
        };
    }

    pub fn deinit(self: *RunAuditStore) void {
        for (self.entries) |e| {
            if (e.run_id.len > 0) self.allocator.free(e.run_id);
            if (e.status.len > 0) self.allocator.free(e.status);
        }
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    /// Enable durable dual-write. Idempotent CREATE TABLE.
    pub fn attachDb(self: *RunAuditStore, db: *DB) !void {
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS ai_run_audit (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  run_id TEXT NOT NULL,
            \\  kind TEXT NOT NULL,
            \\  status TEXT NOT NULL,
            \\  tenant_id INTEGER,
            \\  steps INTEGER NOT NULL DEFAULT 0,
            \\  duration_ms INTEGER NOT NULL DEFAULT 0,
            \\  created_at_ms INTEGER NOT NULL
            \\)
        );
        self.db = db;
    }

    pub fn record(self: *RunAuditStore, entry: RunAuditEntry) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);

        const slot = &self.entries[self.next];
        if (slot.run_id.len > 0) self.allocator.free(slot.run_id);
        if (slot.status.len > 0) self.allocator.free(slot.status);

        const created = if (entry.created_at_ms != 0) entry.created_at_ms else time_util.nowMillis();
        slot.* = .{
            .run_id = self.allocator.dupe(u8, entry.run_id) catch "",
            .kind = entry.kind,
            .status = self.allocator.dupe(u8, entry.status) catch "",
            .tenant_id = entry.tenant_id,
            .steps = entry.steps,
            .duration_ms = entry.duration_ms,
            .created_at_ms = created,
        };
        self.next = (self.next + 1) % self.entries.len;
        if (self.count < self.entries.len) self.count += 1;

        if (self.db) |db| {
            persistDb(db, .{
                .run_id = slot.run_id,
                .kind = slot.kind,
                .status = slot.status,
                .tenant_id = slot.tenant_id,
                .steps = slot.steps,
                .duration_ms = slot.duration_ms,
                .created_at_ms = created,
            }) catch {};
        }
    }

    fn persistDb(db: *DB, entry: RunAuditEntry) !void {
        const zsql = "INSERT INTO ai_run_audit (run_id, kind, status, tenant_id, steps, duration_ms, created_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?)";
        const params = [_]SqlParam{
            .{ .text = entry.run_id },
            .{ .text = @tagName(entry.kind) },
            .{ .text = entry.status },
            if (entry.tenant_id) |t| .{ .int = t } else .null,
            .{ .int = @intCast(entry.steps) },
            .{ .int = entry.duration_ms },
            .{ .int = entry.created_at_ms },
        };
        try db.execParams(zsql, &params);
    }

    /// Newest-first from the in-memory ring (caller frees strings).
    pub fn list(
        self: *RunAuditStore,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(RunAuditEntry),
        kind: ?RunKind,
        tenant_id: ?i64,
        limit: usize,
    ) !void {
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);

        var emitted: usize = 0;
        var i: usize = 0;
        while (i < self.count and emitted < limit) : (i += 1) {
            const idx = (self.next + self.entries.len - 1 - i) % self.entries.len;
            const e = self.entries[idx];
            if (kind) |k| if (e.kind != k) continue;
            if (tenant_id) |tid| {
                const et = e.tenant_id orelse continue;
                if (et != tid) continue;
            }
            try out.append(allocator, .{
                .run_id = try allocator.dupe(u8, e.run_id),
                .kind = e.kind,
                .status = try allocator.dupe(u8, e.status),
                .tenant_id = e.tenant_id,
                .steps = e.steps,
                .duration_ms = e.duration_ms,
                .created_at_ms = e.created_at_ms,
            });
            emitted += 1;
        }
    }

    /// Load newest-first from SQLite (requires `attachDb`). Caller frees strings.
    pub fn listFromDb(
        self: *RunAuditStore,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(RunAuditEntry),
        limit: usize,
    ) !void {
        const db = self.db orelse return error.DbNotAttached;
        var sql_buf: [160]u8 = undefined;
        const sql = try std.fmt.bufPrint(&sql_buf, "SELECT run_id, kind, status, tenant_id, steps, duration_ms, created_at_ms FROM ai_run_audit ORDER BY id DESC LIMIT {d}", .{limit});
        const sql_z = try allocator.allocSentinel(u8, sql.len, 0);
        defer allocator.free(sql_z);
        @memcpy(sql_z[0..sql.len], sql);

        var rs = try db.query(sql_z);
        defer rs.deinit();
        while (rs.next()) {
            const row = rs.currentRowMut() orelse continue;
            const run_id = row.getText(0) orelse "";
            const kind_s = row.getText(1) orelse "agent";
            const status = row.getText(2) orelse "";
            const tenant = row.getInt(3) catch null;
            const steps = row.getInt(4) catch null;
            const dur = row.getInt(5) catch null;
            const created = row.getInt(6) catch null;
            try out.append(allocator, .{
                .run_id = try allocator.dupe(u8, run_id),
                .kind = std.meta.stringToEnum(RunKind, kind_s) orelse .agent,
                .status = try allocator.dupe(u8, status),
                .tenant_id = tenant,
                .steps = @intCast(steps orelse 0),
                .duration_ms = dur orelse 0,
                .created_at_ms = created orelse 0,
            });
        }
    }

    pub fn dumpJson(self: *RunAuditStore, allocator: std.mem.Allocator) ![]u8 {
        var entries = std.ArrayList(RunAuditEntry).empty;
        defer {
            for (entries.items) |e| {
                allocator.free(e.run_id);
                allocator.free(e.status);
            }
            entries.deinit(allocator);
        }
        try self.list(allocator, &entries, null, null, self.count);

        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, "[");
        for (entries.items, 0..) |e, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"run_id\":\"");
            try appendJsonEscaped(&buf, allocator, e.run_id);
            try buf.print(allocator, "\",\"kind\":\"{s}\",\"status\":\"", .{@tagName(e.kind)});
            try appendJsonEscaped(&buf, allocator, e.status);
            try buf.appendSlice(allocator, "\",\"tenant_id\":");
            if (e.tenant_id) |t| {
                try buf.print(allocator, "{d}", .{t});
            } else {
                try buf.appendSlice(allocator, "null");
            }
            try buf.print(allocator, ",\"steps\":{d},\"duration_ms\":{d},\"created_at_ms\":{d}", .{
                e.steps, e.duration_ms, e.created_at_ms,
            });
            try buf.append(allocator, '}');
        }
        try buf.append(allocator, ']');
        return try buf.toOwnedSlice(allocator);
    }

    pub fn saveToFile(self: *RunAuditStore, allocator: std.mem.Allocator, path: []const u8) !void {
        const json = try self.dumpJson(allocator);
        defer allocator.free(json);
        var file = try std.Io.Dir.cwd().createFile(self.io, path, .{});
        defer file.close(self.io);
        try std.Io.File.writeStreamingAll(file, self.io, json);
    }
};

fn appendJsonEscaped(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
}

test "RunAuditStore records and lists with filters" {
    const allocator = std.testing.allocator;
    var store = try RunAuditStore.init(allocator, std.testing.io, 8);
    defer store.deinit();

    store.record(.{ .run_id = "r1", .kind = .workflow, .status = "completed", .tenant_id = 1, .steps = 3, .duration_ms = 12 });
    store.record(.{ .run_id = "r2", .kind = .agent, .status = "completed", .tenant_id = 2, .steps = 1, .duration_ms = 4 });
    store.record(.{ .run_id = "r3", .kind = .workflow, .status = "failed", .tenant_id = 1, .steps = 1, .duration_ms = 9 });

    try std.testing.expectEqual(@as(usize, 3), store.count);

    var all = std.ArrayList(RunAuditEntry).empty;
    defer {
        for (all.items) |e| {
            allocator.free(e.run_id);
            allocator.free(e.status);
        }
        all.deinit(allocator);
    }
    try store.list(allocator, &all, null, null, 10);
    try std.testing.expectEqual(@as(usize, 3), all.items.len);
    try std.testing.expectEqualStrings("r3", all.items[0].run_id);

    const json = try store.dumpJson(allocator);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"run_id\":\"r1\"") != null);
}

test "RunAuditStore attachDb dual-write and listFromDb" {
    const allocator = std.testing.allocator;
    const DBConfig = @import("../db/config.zig").DBConfig;
    var db = try DB.init(allocator, DBConfig.sqliteMemory());
    defer db.destroy();

    var store = try RunAuditStore.init(allocator, std.testing.io, 4);
    defer store.deinit();
    try store.attachDb(db);
    store.record(.{ .run_id = "persist-1", .kind = .agent, .status = "completed", .steps = 2, .duration_ms = 5 });

    var from_db = std.ArrayList(RunAuditEntry).empty;
    defer {
        for (from_db.items) |e| {
            allocator.free(e.run_id);
            allocator.free(e.status);
        }
        from_db.deinit(allocator);
    }
    try store.listFromDb(allocator, &from_db, 10);
    try std.testing.expectEqual(@as(usize, 1), from_db.items.len);
    try std.testing.expectEqualStrings("persist-1", from_db.items[0].run_id);
}
