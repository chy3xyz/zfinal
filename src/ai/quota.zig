//! Per-tenant token quota for multi-tenant AI chat / agent.

const std = @import("std");
const DB = @import("../db/db.zig").DB;
const SqlParam = @import("../db/sql_param.zig").SqlParam;
const time_util = @import("time_util.zig");

pub const TokenQuota = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    buckets: std.AutoHashMap(i64, Bucket),
    default_limit: usize,
    /// Wall-clock period start (ms). `resetIfStale` clears used when elapsed ≥ `period_ms`.
    period_start_ms: i64 = 0,
    period_ms: i64 = 0,
    reset_total: usize = 0,
    db: ?*DB = null,

    pub const Bucket = struct {
        limit: usize,
        used: usize = 0,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, default_limit: usize) TokenQuota {
        return .{
            .allocator = allocator,
            .io = io,
            .mutex = .init,
            .buckets = std.AutoHashMap(i64, Bucket).init(allocator),
            .default_limit = if (default_limit == 0) 1_000_000 else default_limit,
        };
    }

    /// Enable periodic reset (e.g. daily = 86_400_000). Starts the clock now.
    pub fn setPeriodMs(self: *TokenQuota, period_ms: i64) void {
        self.period_ms = period_ms;
        self.period_start_ms = time_util.nowMillis();
    }

    pub fn deinit(self: *TokenQuota) void {
        self.buckets.deinit();
        self.* = undefined;
    }

    /// Dual-write buckets into `ai_token_quota`. Loads existing rows into memory.
    pub fn attachDb(self: *TokenQuota, db: *DB) !void {
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS ai_token_quota (
            \\  tenant_id INTEGER PRIMARY KEY,
            \\  limit_n INTEGER NOT NULL,
            \\  used_n INTEGER NOT NULL DEFAULT 0,
            \\  period_start_ms INTEGER NOT NULL DEFAULT 0,
            \\  period_ms INTEGER NOT NULL DEFAULT 0
            \\)
        );
        self.db = db;
        var rs = try db.query("SELECT tenant_id, limit_n, used_n, period_start_ms, period_ms FROM ai_token_quota");
        defer rs.deinit();
        self.mutex.lock(self.io) catch return error.QuotaLockFailed;
        defer self.mutex.unlock(self.io);
        while (rs.next()) {
            const row = rs.currentRowMut() orelse continue;
            const tid = (try row.getInt(0)) orelse continue;
            const limit_n: usize = @intCast((try row.getInt(1)) orelse @as(i64, @intCast(self.default_limit)));
            const used_n: usize = @intCast((try row.getInt(2)) orelse 0);
            const ps = (try row.getInt(3)) orelse 0;
            const pm = (try row.getInt(4)) orelse 0;
            if (self.period_ms == 0 and pm > 0) {
                self.period_ms = pm;
                self.period_start_ms = ps;
            }
            try self.buckets.put(tid, .{ .limit = limit_n, .used = used_n });
        }
    }

    fn persistLocked(self: *TokenQuota, tenant_id: i64, b: Bucket) void {
        const db = self.db orelse return;
        const params = [_]SqlParam{
            .{ .int = tenant_id },
            .{ .int = @intCast(b.limit) },
            .{ .int = @intCast(b.used) },
            .{ .int = self.period_start_ms },
            .{ .int = self.period_ms },
        };
        db.execParams(
            "INSERT OR REPLACE INTO ai_token_quota (tenant_id, limit_n, used_n, period_start_ms, period_ms) VALUES (?, ?, ?, ?, ?)",
            &params,
        ) catch {};
    }

    /// If `period_ms` elapsed, zero all `used` counters and bump `reset_total`.
    pub fn resetIfStale(self: *TokenQuota) void {
        if (self.period_ms <= 0) return;
        const now = time_util.nowMillis();
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        if (now - self.period_start_ms < self.period_ms) return;
        var it = self.buckets.iterator();
        while (it.next()) |e| {
            e.value_ptr.used = 0;
            self.persistLocked(e.key_ptr.*, e.value_ptr.*);
        }
        self.period_start_ms = now;
        self.reset_total += 1;
    }

    pub fn dumpJson(self: *TokenQuota, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock(self.io) catch return error.QuotaLockFailed;
        defer self.mutex.unlock(self.io);
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{\"period_start_ms\":");
        try buf.print(allocator, "{d},\"period_ms\":{d},\"buckets\":[", .{ self.period_start_ms, self.period_ms });
        var first = true;
        var it = self.buckets.iterator();
        while (it.next()) |e| {
            if (!first) try buf.appendSlice(allocator, ",");
            first = false;
            try buf.print(allocator, "{{\"tenant_id\":{d},\"limit\":{d},\"used\":{d}}}", .{
                e.key_ptr.*, e.value_ptr.limit, e.value_ptr.used,
            });
        }
        try buf.appendSlice(allocator, "]}");
        return try buf.toOwnedSlice(allocator);
    }

    pub fn loadJson(self: *TokenQuota, json_body: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json_body, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidQuotaJson;
        const obj = parsed.value.object;
        self.mutex.lock(self.io) catch return error.QuotaLockFailed;
        defer self.mutex.unlock(self.io);
        if (obj.get("period_start_ms")) |v| {
            if (v == .integer) self.period_start_ms = v.integer;
        }
        if (obj.get("period_ms")) |v| {
            if (v == .integer) self.period_ms = v.integer;
        }
        const arr = (obj.get("buckets") orelse return).array;
        for (arr.items) |item| {
            if (item != .object) continue;
            const o = item.object;
            const tid = (o.get("tenant_id") orelse continue).integer;
            const limit: usize = @intCast((o.get("limit") orelse continue).integer);
            const used_n: usize = @intCast((o.get("used") orelse continue).integer);
            try self.buckets.put(@intCast(tid), .{ .limit = limit, .used = used_n });
        }
    }

    pub fn setLimit(self: *TokenQuota, tenant_id: i64, limit: usize) !void {
        self.resetIfStale();
        self.mutex.lock(self.io) catch return error.QuotaLockFailed;
        defer self.mutex.unlock(self.io);
        const gop = try self.buckets.getOrPut(tenant_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .limit = limit, .used = 0 };
        } else {
            gop.value_ptr.limit = limit;
        }
        self.persistLocked(tenant_id, gop.value_ptr.*);
    }

    pub fn tryConsume(self: *TokenQuota, tenant_id: i64, tokens: usize) !void {
        if (tokens == 0) return;
        self.resetIfStale();
        self.mutex.lock(self.io) catch return error.QuotaLockFailed;
        defer self.mutex.unlock(self.io);

        const gop = try self.buckets.getOrPut(tenant_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .limit = self.default_limit, .used = 0 };
        }
        const b = gop.value_ptr;
        if (b.used + tokens > b.limit) return error.QuotaExceeded;
        b.used += tokens;
        self.persistLocked(tenant_id, b.*);
    }

    pub fn record(self: *TokenQuota, tenant_id: i64, prompt_tokens: usize, completion_tokens: usize) !void {
        try self.tryConsume(tenant_id, prompt_tokens +% completion_tokens);
    }

    pub fn used(self: *TokenQuota, tenant_id: i64) usize {
        self.resetIfStale();
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        const b = self.buckets.get(tenant_id) orelse return 0;
        return b.used;
    }

    pub fn remaining(self: *TokenQuota, tenant_id: i64) usize {
        self.resetIfStale();
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        const b = self.buckets.get(tenant_id) orelse return self.default_limit;
        if (b.used >= b.limit) return 0;
        return b.limit - b.used;
    }

    pub fn toPrometheusFormat(self: *TokenQuota, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock(self.io) catch return error.QuotaLockFailed;
        defer self.mutex.unlock(self.io);

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try buf.print(allocator, "# HELP zfinal_ai_token_quota_used Tokens consumed per tenant.\n", .{});
        try buf.print(allocator, "# TYPE zfinal_ai_token_quota_used gauge\n", .{});
        var it = self.buckets.iterator();
        while (it.next()) |e| {
            try buf.print(allocator, "zfinal_ai_token_quota_used{{tenant_id=\"{d}\"}} {d}\n", .{ e.key_ptr.*, e.value_ptr.used });
            try buf.print(allocator, "zfinal_ai_token_quota_limit{{tenant_id=\"{d}\"}} {d}\n", .{ e.key_ptr.*, e.value_ptr.limit });
        }
        try buf.print(allocator, "# HELP zfinal_ai_token_quota_resets_total Period resets.\n", .{});
        try buf.print(allocator, "# TYPE zfinal_ai_token_quota_resets_total counter\n", .{});
        try buf.print(allocator, "zfinal_ai_token_quota_resets_total {d}\n", .{self.reset_total});
        return try buf.toOwnedSlice(allocator);
    }
};

test "TokenQuota tryConsume" {
    const a = std.testing.allocator;
    var q = TokenQuota.init(a, std.testing.io, 10);
    defer q.deinit();
    try q.tryConsume(1, 6);
    try q.tryConsume(1, 4);
    try std.testing.expectError(error.QuotaExceeded, q.tryConsume(1, 1));
}

test "TokenQuota setLimit used remaining prometheus" {
    const a = std.testing.allocator;
    var q = TokenQuota.init(a, std.testing.io, 100);
    defer q.deinit();
    try q.record(7, 40, 40);
    try std.testing.expectEqual(@as(usize, 80), q.used(7));
    try std.testing.expectEqual(@as(usize, 20), q.remaining(7));
    try q.setLimit(7, 200);
    try q.tryConsume(7, 30);
    try std.testing.expectEqual(@as(usize, 110), q.used(7));

    const out = try q.toPrometheusFormat(a);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "tenant_id=\"7\"") != null);
}

test "TokenQuota dumpJson loadJson roundtrip" {
    const a = std.testing.allocator;
    var q = TokenQuota.init(a, std.testing.io, 100);
    defer q.deinit();
    try q.tryConsume(3, 10);
    const json = try q.dumpJson(a);
    defer a.free(json);
    var q2 = TokenQuota.init(a, std.testing.io, 100);
    defer q2.deinit();
    try q2.loadJson(json);
    try std.testing.expectEqual(@as(usize, 10), q2.used(3));
}

test "TokenQuota attachDb dual-write and reload" {
    const a = std.testing.allocator;
    const DBConfig = @import("../db/config.zig").DBConfig;
    var db = try DB.init(a, DBConfig.sqliteMemory());
    defer db.destroy();
    var q = TokenQuota.init(a, std.testing.io, 50);
    defer q.deinit();
    try q.attachDb(db);
    try q.tryConsume(9, 12);
    try q.setLimit(9, 80);

    var q2 = TokenQuota.init(a, std.testing.io, 50);
    defer q2.deinit();
    try q2.attachDb(db);
    try std.testing.expectEqual(@as(usize, 12), q2.used(9));
    try std.testing.expectEqual(@as(usize, 68), q2.remaining(9));
}
