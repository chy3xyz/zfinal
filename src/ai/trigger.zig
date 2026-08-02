//! Unify cron / event / webhook into one "run an agent workflow" entry point.
//!
//! Optional SQLite idempotency via `attachDb` + `fireIdempotent` (not a full outbox).

const std = @import("std");
const SkillContext = @import("skill.zig").SkillContext;
const CronPlugin = @import("../plugin/cron.zig").CronPlugin;
const DB = @import("../db/db.zig").DB;
const SqlParam = @import("../db/sql_param.zig").SqlParam;
const RunAuditStore = @import("run_audit.zig").RunAuditStore;
const logger = @import("../core/logger.zig");

pub const TriggerResult = struct {
    ok: bool,
    /// Runner-provided; if allocated with the fire() allocator the caller owns it.
    run_id: []const u8 = "",
    message: []const u8 = "",
    /// True when idempotency key was already seen (no runner call).
    duplicate: bool = false,
};

/// Runs the agent / workflow for one trigger. `input` is the payload
/// (cron: captured at register; event/webhook: caller-provided).
pub const TriggerFn = *const fn (
    allocator: std.mem.Allocator,
    ctx: *SkillContext,
    input: []const u8,
    out: *TriggerResult,
) anyerror!void;

pub const Trigger = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    run_fn: TriggerFn,
    /// Template context copied per run (caller sets tenant/backend/userdata).
    ctx_template: SkillContext,
    /// Optional observer after each fire (metrics / logging).
    on_complete: ?*const fn (ctx: ?*anyopaque, result: TriggerResult) void = null,
    on_complete_ctx: ?*anyopaque = null,
    run_audit: ?*RunAuditStore = null,
    db: ?*DB = null,
    cron_ctxs: std.ArrayList(*CronCtx) = .empty,
    fires: usize = 0,
    failures: usize = 0,
    duplicates: usize = 0,

    const CronCtx = struct {
        trigger: *Trigger,
        input: []const u8,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        run_fn: TriggerFn,
        ctx_template: SkillContext,
    ) Trigger {
        return .{ .allocator = allocator, .io = io, .run_fn = run_fn, .ctx_template = ctx_template };
    }

    pub fn deinit(self: *Trigger) void {
        for (self.cron_ctxs.items) |c| {
            self.allocator.free(c.input);
            self.allocator.destroy(c);
        }
        self.cron_ctxs.deinit(self.allocator);
        self.* = undefined;
    }

    /// Optional: `ai_trigger_fires` for `fireIdempotent`.
    pub fn attachDb(self: *Trigger, db: *DB) !void {
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS ai_trigger_fires (
            \\  idempotency_key TEXT PRIMARY KEY,
            \\  created_at_ms INTEGER NOT NULL
            \\)
        );
        self.db = db;
    }

    /// Run now (event / webhook / manual).
    pub fn fire(self: *Trigger, allocator: std.mem.Allocator, input: []const u8) !TriggerResult {
        return self.fireInner(allocator, input, null);
    }

    /// Like `fire`, but skips the runner when `idempotency_key` was already recorded
    /// (`attachDb` required). Returns `duplicate=true`.
    pub fn fireIdempotent(self: *Trigger, allocator: std.mem.Allocator, input: []const u8, idempotency_key: []const u8) !TriggerResult {
        return self.fireInner(allocator, input, idempotency_key);
    }

    fn fireInner(self: *Trigger, allocator: std.mem.Allocator, input: []const u8, idem_key: ?[]const u8) !TriggerResult {
        if (idem_key) |key| {
            const db = self.db orelse return error.TriggerDbRequired;
            const params = [_]SqlParam{ .{ .text = key }, .{ .int = @import("time_util.zig").nowMillis() } };
            db.execParams(
                "INSERT INTO ai_trigger_fires (idempotency_key, created_at_ms) VALUES (?, ?)",
                &params,
            ) catch {
                self.duplicates += 1;
                const dup = TriggerResult{ .ok = true, .duplicate = true, .message = "duplicate" };
                if (self.on_complete) |cb| cb(self.on_complete_ctx, dup);
                return dup;
            };
        }

        self.fires += 1;
        var run_ctx = self.ctx_template;
        var result = TriggerResult{ .ok = false, .run_id = "", .message = "" };
        self.run_fn(allocator, &run_ctx, input, &result) catch |err| {
            self.failures += 1;
            result.ok = false;
            if (result.message.len == 0) {
                result.message = @errorName(err);
            }
            if (self.run_audit) |store| {
                store.record(.{
                    .run_id = if (result.run_id.len > 0) result.run_id else "trigger",
                    .kind = .trigger,
                    .status = "failed",
                    .tenant_id = run_ctx.tenant_id,
                });
            }
            if (self.on_complete) |cb| cb(self.on_complete_ctx, result);
            return result;
        };
        if (!result.ok) self.failures += 1;
        if (self.run_audit) |store| {
            store.record(.{
                .run_id = if (result.run_id.len > 0) result.run_id else "trigger",
                .kind = .trigger,
                .status = if (result.ok) "completed" else "failed",
                .tenant_id = run_ctx.tenant_id,
            });
        }
        if (self.on_complete) |cb| cb(self.on_complete_ctx, result);
        return result;
    }

    /// Attach to a cron expression. Context is owned by the trigger / freed in `deinit`.
    pub fn registerCron(
        self: *Trigger,
        cron: *CronPlugin,
        name: []const u8,
        expr: []const u8,
        input: []const u8,
    ) !void {
        const c = try self.allocator.create(CronCtx);
        errdefer self.allocator.destroy(c);
        c.* = .{ .trigger = self, .input = try self.allocator.dupe(u8, input) };
        try self.cron_ctxs.append(self.allocator, c);
        try cron.scheduleWith(name, expr, cronTask, c);
    }
};

fn cronTask(ctx: *anyopaque) void {
    const c: *Trigger.CronCtx = @ptrCast(@alignCast(ctx));
    const result = c.trigger.fire(c.trigger.allocator, c.input) catch |err| {
        c.trigger.failures += 1;
        logger.getLogger().warnFmt("trigger cron fire error: {t}", .{err});
        return;
    };
    if (!result.ok) {
        logger.getLogger().warnFmt("trigger cron failed: {s}", .{result.message});
    }
}

test "trigger fire runs the workflow and returns the outcome" {
    const allocator = std.testing.allocator;
    const T = struct {
        fn run(a: std.mem.Allocator, _: *SkillContext, input: []const u8, out: *TriggerResult) anyerror!void {
            out.ok = true;
            out.run_id = try a.dupe(u8, "r1");
            out.message = try a.dupe(u8, input);
        }
    };
    const ctx = SkillContext{ .allocator = allocator };
    var trigger = Trigger.init(allocator, std.testing.io, T.run, ctx);
    defer trigger.deinit();
    const result = try trigger.fire(allocator, "hello");
    defer {
        allocator.free(result.run_id);
        allocator.free(result.message);
    }
    try std.testing.expect(result.ok);
    try std.testing.expectEqualStrings("r1", result.run_id);
    try std.testing.expectEqualStrings("hello", result.message);
    try std.testing.expectEqual(@as(usize, 1), trigger.fires);
}

test "trigger fire records runner errors as failure" {
    const allocator = std.testing.allocator;
    const T = struct {
        fn run(_: std.mem.Allocator, _: *SkillContext, _: []const u8, _: *TriggerResult) anyerror!void {
            return error.Boom;
        }
    };
    const ctx = SkillContext{ .allocator = allocator };
    var trigger = Trigger.init(allocator, std.testing.io, T.run, ctx);
    defer trigger.deinit();
    const result = try trigger.fire(allocator, "");
    try std.testing.expect(!result.ok);
    try std.testing.expectEqual(@as(usize, 1), trigger.failures);
}

test "trigger fireIdempotent skips duplicate keys" {
    const allocator = std.testing.allocator;
    const DBConfig = @import("../db/config.zig").DBConfig;
    const T = struct {
        var calls: usize = 0;
        fn run(_: std.mem.Allocator, _: *SkillContext, _: []const u8, out: *TriggerResult) anyerror!void {
            calls += 1;
            out.ok = true;
        }
    };
    T.calls = 0;
    var db = try DB.init(allocator, DBConfig.sqliteMemory());
    defer db.destroy();
    const ctx = SkillContext{ .allocator = allocator };
    var trigger = Trigger.init(allocator, std.testing.io, T.run, ctx);
    defer trigger.deinit();
    try trigger.attachDb(db);
    _ = try trigger.fireIdempotent(allocator, "x", "idem-1");
    const dup = try trigger.fireIdempotent(allocator, "x", "idem-1");
    try std.testing.expect(dup.duplicate);
    try std.testing.expectEqual(@as(usize, 1), T.calls);
    try std.testing.expectEqual(@as(usize, 1), trigger.duplicates);
}
