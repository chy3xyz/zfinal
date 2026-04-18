const std = @import("std");
const Plugin = @import("plugin.zig").Plugin;
const TimeKit = @import("../kit/time_kit.zig").TimeKit;

/// Cron expression parser
/// Format: minute hour day_of_month month day_of_week
/// Supports: * (any), */n (step), n (specific), n-m (range), n,m (list)
pub const CronExpression = struct {
    minutes: [60]bool,
    hours: [24]bool,
    days_of_month: [31]bool,
    months: [12]bool,
    days_of_week: [7]bool,

    const Self = @This();

    /// Parse cron expression string
    pub fn parse(allocator: std.mem.Allocator, expr: []const u8) !CronExpression {
        var cron = CronExpression{
            .minutes = undefined,
            .hours = undefined,
            .days_of_month = undefined,
            .months = undefined,
            .days_of_week = undefined,
        };

        // Initialize all to false
        @memset(&cron.minutes, false);
        @memset(&cron.hours, false);
        @memset(&cron.days_of_month, false);
        @memset(&cron.months, false);
        @memset(&cron.days_of_week, false);

        // Split expression into parts
        var parts = std.ArrayList([]const u8).empty;
        defer parts.deinit(allocator);

        var it = std.mem.splitScalar(u8, expr, ' ');
        while (it.next()) |part| {
            if (part.len > 0) {
                try parts.append(allocator, part);
            }
        }

        if (parts.items.len != 5) return error.InvalidCronExpression;

        try parseField(parts.items[0], 0, 59, &cron.minutes);
        try parseField(parts.items[1], 0, 23, &cron.hours);
        try parseField(parts.items[2], 1, 31, &cron.days_of_month);
        try parseField(parts.items[3], 1, 12, &cron.months);
        try parseField(parts.items[4], 0, 6, &cron.days_of_week);

        return cron;
    }

    /// Parse a single cron field
    fn parseField(field: []const u8, min: usize, max: usize, result: []bool) !void {
        // Handle special cases
        if (std.mem.eql(u8, field, "*")) {
            var i: usize = min;
            while (i <= max) : (i += 1) {
                result[i] = true;
            }
            return;
        }

        // Handle step: */n
        if (std.mem.startsWith(u8, field, "*/")) {
            const step = try std.fmt.parseInt(usize, field[2..], 10);
            if (step == 0) return error.InvalidStep;
            var i: usize = min;
            while (i <= max) : (i += step) {
                result[i] = true;
            }
            return;
        }

        // Handle range: n-m
        if (std.mem.indexOfScalar(u8, field, '-')) |dash_pos| {
            const start = try std.fmt.parseInt(usize, field[0..dash_pos], 10);
            const end = try std.fmt.parseInt(usize, field[dash_pos + 1 ..], 10);
            var i: usize = start;
            while (i <= end and i <= max) : (i += 1) {
                result[i] = true;
            }
            return;
        }

        // Handle list: n,m
        if (std.mem.indexOfScalar(u8, field, ',')) |_| {
            var list_it = std.mem.splitScalar(u8, field, ',');
            while (list_it.next()) |item| {
                const val = try std.fmt.parseInt(usize, item, 10);
                if (val >= min and val <= max) {
                    result[val] = true;
                }
            }
            return;
        }

        // Single value
        const val = try std.fmt.parseInt(usize, field, 10);
        if (val >= min and val <= max) {
            result[val] = true;
        }
    }

    /// Check if the cron expression matches the given time
    pub fn matches(self: *const Self, timestamp: i64) bool {
        const seconds = @as(u64, @intCast(timestamp));
        const epoch_day = seconds / 86400;

        // Calculate day of week (0 = Sunday)
        const days_since_epoch = epoch_day;
        const day_of_week = @mod(days_since_epoch + 4, 7); // Jan 1, 1970 was Thursday

        // Calculate time of day
        const seconds_of_day = seconds % 86400;
        const hour = @divTrunc(seconds_of_day, 3600);
        const minute = @divTrunc(seconds_of_day % 3600, 60);

        // Calculate month and day (simplified - not accounting for leap years perfectly)
        const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        var day_of_year = @mod(days_since_epoch, 365);
        var month: usize = 0;
        var day_of_month: usize = 0;

        for (days_in_month, 0..) |dim, i| {
            if (day_of_year < dim) {
                month = i;
                day_of_month = day_of_year;
                break;
            }
            day_of_year -= dim;
        }

        if (!self.minutes[minute]) return false;
        if (!self.hours[hour]) return false;
        if (!self.days_of_month[day_of_month]) return false;
        if (!self.months[month]) return false;
        if (!self.days_of_week[day_of_week]) return false;

        return true;
    }

    /// Get next scheduled time (simplified)
    pub fn nextRun(self: *const Self, from_timestamp: i64) i64 {
        var ts = from_timestamp + 60; // Start from next minute
        const max_checks = 366 * 24 * 60; // Max 1 year ahead

        var i: usize = 0;
        while (i < max_checks) : (i += 1) {
            if (self.matches(ts)) return ts;
            ts += 60;
        }

        return -1; // No next run found
    }
};

/// Cron job definition
pub const CronJob = struct {
    name: []const u8,
    schedule: CronExpression,
    schedule_str: []const u8,
    task: *const fn () void,
    last_run: i64 = 0,
    next_run: i64 = 0,
    enabled: bool = true,
    run_count: u64 = 0,
};

/// Enhanced cron plugin with proper scheduling
pub const CronPlugin = struct {
    jobs: std.ArrayList(CronJob),
    allocator: std.mem.Allocator,
    running: bool = false,
    thread: ?std.Thread = null,
    name: []const u8 = "cron",
    check_interval_ms: u64 = 1000, // Check every second

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) CronPlugin {
        return CronPlugin{
            .jobs = std.ArrayList(CronJob).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop() catch {};
        for (self.jobs.items) |*job| {
            self.allocator.free(job.name);
        }
        self.jobs.deinit(self.allocator);
    }

    /// Schedule a new cron job
    pub fn schedule(self: *Self, name: []const u8, cron_expr: []const u8, task: *const fn () void) !void {
        const parsed = try CronExpression.parse(self.allocator, cron_expr);

        const now = std.time.timestamp();
        const next_run = parsed.nextRun(now);

        const job = CronJob{
            .name = try self.allocator.dupe(u8, name),
            .schedule = parsed,
            .schedule_str = cron_expr,
            .task = task,
            .last_run = 0,
            .next_run = next_run,
        };

        try self.jobs.append(self.allocator, job);
    }

    /// Remove a scheduled job
    pub fn unschedule(self: *Self, name: []const u8) void {
        for (self.jobs.items, 0..) |*job, i| {
            if (std.mem.eql(u8, job.name, name)) {
                self.allocator.free(job.name);
                _ = self.jobs.orderedRemove(i);
                return;
            }
        }
    }

    /// Enable a job
    pub fn enableJob(self: *Self, name: []const u8) void {
        for (self.jobs.items) |*job| {
            if (std.mem.eql(u8, job.name, name)) {
                job.enabled = true;
                return;
            }
        }
    }

    /// Disable a job
    pub fn disableJob(self: *Self, name: []const u8) void {
        for (self.jobs.items) |*job| {
            if (std.mem.eql(u8, job.name, name)) {
                job.enabled = false;
                return;
            }
        }
    }

    /// Get job count
    pub fn jobCount(self: *const Self) usize {
        return self.jobs.items.len;
    }

    /// Start cron scheduler
    pub fn start(self: *Self) !void {
        if (self.running) return;

        self.running = true;
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    /// Stop cron scheduler
    pub fn stop(self: *Self) !void {
        if (!self.running) return;

        self.running = false;
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    /// Main run loop
    fn runLoop(self: *Self) void {
        while (self.running) {
            const now = std.time.timestamp();

            for (self.jobs.items) |*job| {
                if (!job.enabled) continue;

                if (job.schedule.matches(now)) {
                    if (now - job.last_run >= 60) { // Prevent duplicate runs within same minute
                        std.debug.print("[Cron] Running job: {s} (schedule: {s})\n", .{ job.name, job.schedule_str });
                        job.task();
                        job.last_run = now;
                        job.run_count += 1;
                        job.next_run = job.schedule.nextRun(now);
                    }
                }
            }

            std.time.sleep(self.check_interval_ms * std.time.ns_per_ms);
        }
    }

    // Plugin interface implementation
    pub fn asPlugin(self: *Self) Plugin {
        const vtable = Plugin.VTable{
            .start = startImpl,
            .stop = stopImpl,
        };

        return Plugin{
            .name = self.name,
            .vtable = &vtable,
            .context = self,
        };
    }

    fn startImpl(ctx: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        try self.start();
    }

    fn stopImpl(ctx: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        try self.stop();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "cron expression parse - any" {
    const allocator = std.testing.allocator;

    const cron = try CronExpression.parse(allocator, "* * * * *");

    // Every minute should match
    try std.testing.expect(cron.minutes[0]);
    try std.testing.expect(cron.minutes[30]);
    try std.testing.expect(cron.minutes[59]);
    try std.testing.expect(cron.hours[0]);
    try std.testing.expect(cron.hours[23]);
}

test "cron expression parse - specific" {
    const allocator = std.testing.allocator;

    const cron = try CronExpression.parse(allocator, "30 14 * * *");

    try std.testing.expect(cron.minutes[30]);
    try std.testing.expect(!cron.minutes[0]);
    try std.testing.expect(cron.hours[14]);
    try std.testing.expect(!cron.hours[13]);
}

test "cron expression parse - step" {
    const allocator = std.testing.allocator;

    const cron = try CronExpression.parse(allocator, "*/15 * * * *");

    try std.testing.expect(cron.minutes[0]);
    try std.testing.expect(cron.minutes[15]);
    try std.testing.expect(cron.minutes[30]);
    try std.testing.expect(cron.minutes[45]);
    try std.testing.expect(!cron.minutes[10]);
}

test "cron expression parse - range" {
    const allocator = std.testing.allocator;

    const cron = try CronExpression.parse(allocator, "0 9-17 * * 1-5");

    try std.testing.expect(cron.hours[9]);
    try std.testing.expect(cron.hours[17]);
    try std.testing.expect(!cron.hours[18]);
    try std.testing.expect(cron.days_of_week[1]);
    try std.testing.expect(cron.days_of_week[5]);
    try std.testing.expect(!cron.days_of_week[0]); // Sunday
}

test "cron expression parse - list" {
    const allocator = std.testing.allocator;

    const cron = try CronExpression.parse(allocator, "0,30 * * * *");

    try std.testing.expect(cron.minutes[0]);
    try std.testing.expect(cron.minutes[30]);
    try std.testing.expect(!cron.minutes[15]);
}

test "cron plugin basic" {
    const allocator = std.testing.allocator;

    var cron = CronPlugin.init(allocator);
    defer cron.deinit();

    const testTask = struct {
        fn task() void {}
    }.task;

    try cron.schedule("test_job", "* * * * *", testTask);
    try std.testing.expectEqual(@as(usize, 1), cron.jobs.items.len);

    cron.unschedule("test_job");
    try std.testing.expectEqual(@as(usize, 0), cron.jobs.items.len);
}

test "cron plugin enable disable" {
    const allocator = std.testing.allocator;

    var cron = CronPlugin.init(allocator);
    defer cron.deinit();

    const testTask = struct {
        fn task() void {}
    }.task;

    try cron.schedule("job1", "0 0 * * *", testTask);
    try std.testing.expect(cron.jobs.items[0].enabled);

    cron.disableJob("job1");
    try std.testing.expect(!cron.jobs.items[0].enabled);

    cron.enableJob("job1");
    try std.testing.expect(cron.jobs.items[0].enabled);
}
