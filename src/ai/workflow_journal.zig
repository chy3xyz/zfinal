//! Per-run JSONL step journal — lightweight WAL stand-in for Workflow.
//!
//! One file `{dir}/{run_id}.jsonl`; each line is a step record. Optional
//! `attachDb` dual-writes into `ai_workflow_journal` (survives file loss).
//! Pair with `Workflow.journal` + `run_id`, then `resumeFromJournal`.

const std = @import("std");
const DB = @import("../db/db.zig").DB;
const SqlParam = @import("../db/sql_param.zig").SqlParam;
const time_util = @import("time_util.zig");

pub const JournalLine = struct {
    name: []const u8,
    status: []const u8,
    error_message: ?[]const u8 = null,
    output: []const u8 = "",
};

pub const WorkflowJournal = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    db: ?*DB = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) !WorkflowJournal {
        try std.Io.Dir.cwd().createDirPath(io, dir);
        return .{
            .allocator = allocator,
            .io = io,
            .dir = try allocator.dupe(u8, dir),
        };
    }

    pub fn deinit(self: *WorkflowJournal) void {
        self.allocator.free(self.dir);
        self.* = undefined;
    }

    pub fn attachDb(self: *WorkflowJournal, db: *DB) !void {
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS ai_workflow_journal (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  run_id TEXT NOT NULL,
            \\  name TEXT NOT NULL,
            \\  status TEXT NOT NULL,
            \\  error_message TEXT,
            \\  output TEXT NOT NULL DEFAULT '',
            \\  created_at_ms INTEGER NOT NULL
            \\)
        );
        try db.exec(
            \\CREATE INDEX IF NOT EXISTS idx_ai_wf_journal_run ON ai_workflow_journal(run_id, id)
        );
        self.db = db;
    }

    pub fn pathFor(self: *const WorkflowJournal, allocator: std.mem.Allocator, run_id: []const u8) ![]u8 {
        for (run_id) |c| {
            if (c == '/' or c == '\\' or c == 0) return error.InvalidRunId;
        }
        return std.fmt.allocPrint(allocator, "{s}/{s}.jsonl", .{ self.dir, run_id });
    }

    pub fn append(self: *WorkflowJournal, run_id: []const u8, line: JournalLine) !void {
        const path = try self.pathFor(self.allocator, run_id);
        defer self.allocator.free(path);

        const json = try std.json.Stringify.valueAlloc(self.allocator, .{
            .name = line.name,
            .status = line.status,
            .error_message = line.error_message,
            .output = line.output,
        }, .{});
        defer self.allocator.free(json);

        var existing: []const u8 = "";
        var existing_owned: ?[]u8 = null;
        defer if (existing_owned) |b| self.allocator.free(b);

        if (std.Io.Dir.cwd().openFile(self.io, path, .{})) |file| {
            defer file.close(self.io);
            if (file.stat(self.io)) |stat| {
                const size: usize = @intCast(stat.size);
                if (size > 0) {
                    const buf = try self.allocator.alloc(u8, size);
                    errdefer self.allocator.free(buf);
                    const n = try std.Io.File.readPositionalAll(file, self.io, buf, 0);
                    existing_owned = buf;
                    existing = buf[0..n];
                }
            } else |_| {}
        } else |_| {}

        const merged = try std.fmt.allocPrint(self.allocator, "{s}{s}\n", .{ existing, json });
        defer self.allocator.free(merged);
        const out = try std.Io.Dir.cwd().createFile(self.io, path, .{});
        defer out.close(self.io);
        try std.Io.File.writeStreamingAll(out, self.io, merged);

        if (self.db) |db| {
            const err_p: SqlParam = if (line.error_message) |e| .{ .text = e } else .null;
            const params = [_]SqlParam{
                .{ .text = run_id },
                .{ .text = line.name },
                .{ .text = line.status },
                err_p,
                .{ .text = line.output },
                .{ .int = time_util.nowMillis() },
            };
            try db.execParams(
                "INSERT INTO ai_workflow_journal (run_id, name, status, error_message, output, created_at_ms) VALUES (?, ?, ?, ?, ?, ?)",
                &params,
            );
        }
    }

    /// Load lines (caller frees via `freeLines`). Prefers DB when attached.
    pub fn loadLines(
        self: *WorkflowJournal,
        allocator: std.mem.Allocator,
        run_id: []const u8,
        out: *std.ArrayList(JournalLine),
    ) !void {
        if (self.db) |db| {
            const params = [_]SqlParam{.{ .text = run_id }};
            var rs = try db.queryParams(
                "SELECT name, status, error_message, output FROM ai_workflow_journal WHERE run_id = ? ORDER BY id ASC",
                &params,
            );
            defer rs.deinit();
            while (rs.next()) {
                const row = rs.currentRowMut() orelse continue;
                const err_msg = row.getText(2);
                try out.append(allocator, .{
                    .name = try allocator.dupe(u8, row.getText(0) orelse ""),
                    .status = try allocator.dupe(u8, row.getText(1) orelse "completed"),
                    .error_message = if (err_msg) |e| try allocator.dupe(u8, e) else null,
                    .output = try allocator.dupe(u8, row.getText(3) orelse ""),
                });
            }
            if (out.items.len > 0) return;
        }

        const path = try self.pathFor(allocator, run_id);
        defer allocator.free(path);

        const file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        const raw = try allocator.alloc(u8, @as(usize, @intCast(stat.size)));
        defer allocator.free(raw);
        const n = try std.Io.File.readPositionalAll(file, self.io, raw, 0);

        var it = std.mem.splitScalar(u8, raw[0..n], '\n');
        while (it.next()) |row| {
            if (row.len == 0) continue;
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, row, .{});
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const obj = parsed.value.object;
            const name = switch (obj.get("name") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            const st_s: []const u8 = blk: {
                const sv = obj.get("status") orelse break :blk "completed";
                break :blk switch (sv) {
                    .string => |s| s,
                    else => "completed",
                };
            };
            const output: []const u8 = blk: {
                const ov = obj.get("output") orelse break :blk "";
                break :blk switch (ov) {
                    .string => |s| s,
                    else => "",
                };
            };
            const err_msg: ?[]const u8 = blk: {
                const ev = obj.get("error_message") orelse break :blk null;
                break :blk switch (ev) {
                    .string => |s| s,
                    .null => null,
                    else => null,
                };
            };
            try out.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .status = try allocator.dupe(u8, st_s),
                .error_message = if (err_msg) |e| try allocator.dupe(u8, e) else null,
                .output = try allocator.dupe(u8, output),
            });
        }
    }

    pub fn freeLines(allocator: std.mem.Allocator, lines: []JournalLine) void {
        for (lines) |l| {
            allocator.free(l.name);
            allocator.free(l.status);
            if (l.error_message) |e| allocator.free(e);
            if (l.output.len > 0) allocator.free(l.output);
        }
    }

    pub fn delete(self: *WorkflowJournal, run_id: []const u8) void {
        const path = self.pathFor(self.allocator, run_id) catch return;
        defer self.allocator.free(path);
        std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
        if (self.db) |db| {
            const params = [_]SqlParam{.{ .text = run_id }};
            db.execParams("DELETE FROM ai_workflow_journal WHERE run_id = ?", &params) catch {};
        }
    }
};

test "WorkflowJournal append and loadLines roundtrip" {
    const allocator = std.testing.allocator;
    const dir = "zfinal-test-wf-journal";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var journal = try WorkflowJournal.init(allocator, std.testing.io, dir);
    defer journal.deinit();

    try journal.append("run-1", .{ .name = "a", .status = "completed", .output = "ok" });
    try journal.append("run-1", .{
        .name = "b",
        .status = "pending_human",
        .output = "{\"status\":\"pending_human\",\"run_id\":\"ap-1\"}",
    });

    var lines = std.ArrayList(JournalLine).empty;
    defer {
        WorkflowJournal.freeLines(allocator, lines.items);
        lines.deinit(allocator);
    }
    try journal.loadLines(allocator, "run-1", &lines);
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("pending_human", lines.items[1].status);
}

test "WorkflowJournal attachDb dual-write survives without file" {
    const allocator = std.testing.allocator;
    const DBConfig = @import("../db/config.zig").DBConfig;
    const dir = "zfinal-test-wf-journal-db";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var db = try DB.init(allocator, DBConfig.sqliteMemory());
    defer db.destroy();

    var journal = try WorkflowJournal.init(allocator, std.testing.io, dir);
    defer journal.deinit();
    try journal.attachDb(db);
    try journal.append("run-db2", .{ .name = "x", .status = "completed", .output = "z" });

    const path = try journal.pathFor(allocator, "run-db2");
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var lines = std.ArrayList(JournalLine).empty;
    defer {
        WorkflowJournal.freeLines(allocator, lines.items);
        lines.deinit(allocator);
    }
    try journal.loadLines(allocator, "run-db2", &lines);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("z", lines.items[0].output);
}
