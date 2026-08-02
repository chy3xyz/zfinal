//! Ring-buffer audit trail for agent tool calls and run lifecycle.
//! Optional `attachDb` dual-writes into `ai_tool_audit`.

const std = @import("std");
const time_util = @import("time_util.zig");
const DB = @import("../db/db.zig").DB;
const SqlParam = @import("../db/sql_param.zig").SqlParam;

pub const AuditKind = enum {
    run_start,
    tool_ok,
    tool_err,
    tool_denied,
    run_finish,
    run_max_steps,

    pub fn asText(self: AuditKind) []const u8 {
        return switch (self) {
            .run_start => "run_start",
            .tool_ok => "tool_ok",
            .tool_err => "tool_err",
            .tool_denied => "tool_denied",
            .run_finish => "run_finish",
            .run_max_steps => "run_max_steps",
        };
    }
};

pub const AuditEvent = struct {
    kind: AuditKind,
    tool_name: []const u8 = "",
    detail: []const u8 = "",
    tenant_id: i64 = 0,
    user_id: i64 = 0,
    at_ms: i64 = 0,
};

pub const AgentAuditLog = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    events: []AuditEvent,
    next: usize = 0,
    count: usize = 0,
    db: ?*DB = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, capacity: usize) !AgentAuditLog {
        const cap = if (capacity == 0) 64 else capacity;
        const events = try allocator.alloc(AuditEvent, cap);
        for (events) |*e| e.* = .{ .kind = .run_start };
        return .{
            .allocator = allocator,
            .io = io,
            .mutex = .init,
            .events = events,
        };
    }

    pub fn deinit(self: *AgentAuditLog) void {
        for (self.events) |e| {
            if (e.tool_name.len > 0) self.allocator.free(e.tool_name);
            if (e.detail.len > 0) self.allocator.free(e.detail);
        }
        self.allocator.free(self.events);
        self.* = undefined;
    }

    pub fn attachDb(self: *AgentAuditLog, db: *DB) !void {
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS ai_tool_audit (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  kind TEXT NOT NULL,
            \\  tool_name TEXT NOT NULL DEFAULT '',
            \\  detail TEXT NOT NULL DEFAULT '',
            \\  tenant_id INTEGER NOT NULL DEFAULT 0,
            \\  user_id INTEGER NOT NULL DEFAULT 0,
            \\  at_ms INTEGER NOT NULL
            \\)
        );
        self.db = db;
    }

    pub fn record(
        self: *AgentAuditLog,
        kind: AuditKind,
        tool_name: []const u8,
        detail: []const u8,
        tenant_id: i64,
        user_id: i64,
    ) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);

        const slot = &self.events[self.next];
        if (slot.tool_name.len > 0) self.allocator.free(slot.tool_name);
        if (slot.detail.len > 0) self.allocator.free(slot.detail);

        const at = time_util.nowMillis();
        slot.* = .{
            .kind = kind,
            .tool_name = self.allocator.dupe(u8, tool_name) catch "",
            .detail = self.allocator.dupe(u8, detail) catch "",
            .tenant_id = tenant_id,
            .user_id = user_id,
            .at_ms = at,
        };
        self.next = (self.next + 1) % self.events.len;
        if (self.count < self.events.len) self.count += 1;

        if (self.db) |db| {
            const params = [_]SqlParam{
                .{ .text = kind.asText() },
                .{ .text = slot.tool_name },
                .{ .text = slot.detail },
                .{ .int = tenant_id },
                .{ .int = user_id },
                .{ .int = at },
            };
            db.execParams(
                "INSERT INTO ai_tool_audit (kind, tool_name, detail, tenant_id, user_id, at_ms) VALUES (?, ?, ?, ?, ?, ?)",
                &params,
            ) catch {};
        }
    }
};

test "AgentAuditLog records" {
    const a = std.testing.allocator;
    var log = try AgentAuditLog.init(a, std.testing.io, 4);
    defer log.deinit();
    log.record(.run_start, "", "goal", 1, 2);
    try std.testing.expectEqual(@as(usize, 1), log.count);
}

test "AgentAuditLog attachDb dual-write" {
    const a = std.testing.allocator;
    const DBConfig = @import("../db/config.zig").DBConfig;
    var db = try DB.init(a, DBConfig.sqliteMemory());
    defer db.destroy();
    var log = try AgentAuditLog.init(a, std.testing.io, 8);
    defer log.deinit();
    try log.attachDb(db);
    log.record(.tool_ok, "db.query", "ok", 7, 1);
    var rs = try db.query("SELECT COUNT(*) AS c FROM ai_tool_audit");
    defer rs.deinit();
    try std.testing.expect(rs.next());
    try std.testing.expectEqual(@as(i64, 1), (try rs.currentRow().?.getInt(0)).?);
}
