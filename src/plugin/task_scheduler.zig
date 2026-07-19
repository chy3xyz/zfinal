const std = @import("std");
const io_instance = @import("../io_instance.zig");
const CronPlugin = @import("cron.zig").CronPlugin;

/// Combines cron jobs (via CronPlugin) with fixed-rate / fixed-delay tasks.
/// Call `tick()` periodically from your event loop (or a dedicated thread).
pub const TaskScheduler = struct {
    allocator: std.mem.Allocator,
    cron: CronPlugin,
    fixed: std.ArrayList(FixedTask) = .empty,

    pub const Handler = *const fn () void;

    pub const FixedTask = struct {
        name: []const u8,
        interval_ms: u64,
        handler: Handler,
        last_run_ms: i64 = 0,
        /// When true, wait `interval_ms` after each run finishes (delay).
        /// When false, fire every `interval_ms` from last fire (rate).
        fixed_delay: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator) TaskScheduler {
        return .{
            .allocator = allocator,
            .cron = CronPlugin.init(allocator),
        };
    }

    pub fn deinit(self: *TaskScheduler) void {
        self.cron.deinit();
        for (self.fixed.items) |t| self.allocator.free(t.name);
        self.fixed.deinit(self.allocator);
    }

    pub fn scheduleCron(self: *TaskScheduler, name: []const u8, cron_expr: []const u8, handler: Handler) !void {
        try self.cron.schedule(name, cron_expr, handler);
    }

    pub fn scheduleFixedRate(self: *TaskScheduler, name: []const u8, interval_ms: u64, handler: Handler) !void {
        try self.fixed.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .interval_ms = interval_ms,
            .handler = handler,
            .fixed_delay = false,
        });
    }

    pub fn scheduleFixedDelay(self: *TaskScheduler, name: []const u8, interval_ms: u64, handler: Handler) !void {
        try self.fixed.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .interval_ms = interval_ms,
            .handler = handler,
            .fixed_delay = true,
        });
    }

    /// Run due cron + fixed tasks once.
    pub fn tick(self: *TaskScheduler) void {
        self.cron.tick();
        const now = std.Io.Timestamp.now(io_instance.io, .real).toMilliseconds();
        for (self.fixed.items) |*t| {
            if (t.last_run_ms == 0 or now - t.last_run_ms >= @as(i64, @intCast(t.interval_ms))) {
                t.handler();
                t.last_run_ms = now;
            }
        }
    }

    pub fn fixedCount(self: *const TaskScheduler) usize {
        return self.fixed.items.len;
    }
};

test "task scheduler: fixed rate fires" {
    const a = std.testing.allocator;
    var s = TaskScheduler.init(a);
    defer s.deinit();

    const Counter = struct {
        var n: usize = 0;
        fn bump() void {
            n += 1;
        }
    };
    Counter.n = 0;
    try s.scheduleFixedRate("c", 1, Counter.bump);
    s.tick();
    s.tick();
    try std.testing.expect(Counter.n >= 1);
}
