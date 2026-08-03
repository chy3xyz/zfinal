//! Minimal fixed-interval task runner (P0) — subscription expiry + invite cleanup.
//!
//! Mirrors the `zf g task` runner shape: register() tasks with an interval,
//! start() spawns one detached thread that ticks and runs due tasks.
const std = @import("std");
const zfinal = @import("zfinal");

pub const Task = struct {
    name: []const u8,
    interval_sec: i64,
    last_run_unix: i64 = 0,
    run: *const fn (db: *zfinal.DB, allocator: std.mem.Allocator) void,
};

var tasks: std.ArrayList(Task) = .empty;
var tick_sec: i64 = 10;

pub fn register(allocator: std.mem.Allocator, task: Task) !void {
    try tasks.append(allocator, task);
}

fn nowUnix() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @intCast(ts.sec);
}

/// Spawn the runner thread (detached). Call after register().
pub fn start(db: *zfinal.DB, allocator: std.mem.Allocator) !void {
    const thread = try std.Thread.spawn(.{}, runLoop, .{ db, allocator });
    thread.detach();
}

fn sleepSec(sec: i64) void {
    var ts: std.c.timespec = .{ .sec = sec, .nsec = 0 };
    _ = std.c.nanosleep(&ts, null);
}

fn runLoop(db: *zfinal.DB, allocator: std.mem.Allocator) void {
    while (true) {
        sleepSec(tick_sec);
        const now = nowUnix();
        for (tasks.items) |*task| {
            if (now - task.last_run_unix >= task.interval_sec) {
                task.last_run_unix = now;
                task.run(db, allocator);
            }
        }
    }
}

// ── Built-in SaaS tasks ──────────────────────────────────────────────────────

/// Downgrade expired active/trialing subscriptions to inactive.
pub fn expireSubscriptions(db: *zfinal.DB, _: std.mem.Allocator) void {
    db.exec(
        \\UPDATE subscriptions SET status = 'inactive', updated_at = datetime('now')
        \\WHERE status IN ('active','trialing') AND current_period_end IS NOT NULL
        \\AND current_period_end < datetime('now')
    ) catch {
        zfinal.getLogger().err("task: subscription expiry failed", .{});
        return;
    };
    zfinal.getLogger().info("task: subscription expiry sweep done", .{});
}

/// Delete unaccepted invites past their expiry (keeps accepted ones as history).
pub fn cleanupInvites(db: *zfinal.DB, _: std.mem.Allocator) void {
    db.exec(
        \\DELETE FROM invitations WHERE accepted_at IS NULL AND expires_at < strftime('%s','now')
    ) catch {
        zfinal.getLogger().err("task: invite cleanup failed", .{});
        return;
    };
    zfinal.getLogger().info("task: invite cleanup sweep done", .{});
}
