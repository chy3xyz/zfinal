const std = @import("std");
const Plugin = @import("plugin.zig").Plugin;
const TimeKit = @import("../kit/time_kit.zig").TimeKit;

/// Cron expression parser
/// Format: minute hour day_of_month month day_of_week
/// Supports: * (any), */n (step), n (specific), n-m (range), n,m (list)
pub const CronExpression = struct {
    minutes: [60]bool,
    hours: [24]bool,
    days_of_month: [32]bool,
    months: [13]bool,
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
        const minutes = (seconds / 60) % 60;
        const hours = (seconds / 3600) % 24;

        // Get day components using TimeKit
        const days = seconds / 86400;
        const day_of_week = @as(u8, @intCast(days % 7));
        const day_of_month = TimeKit.getDayOfMonth(timestamp);
        const month = TimeKit.getMonth(timestamp);

        // Check each field
        if (!self.minutes[minutes]) return false;
        if (!self.hours[hours]) return false;
        if (!self.days_of_month[day_of_month]) return false;
        if (!self.months[month]) return false;
        if (!self.days_of_week[day_of_week]) return false;

        return true;
    }

    /// Get next run time after the given timestamp
    pub fn nextRun(self: *const Self, timestamp: i64) i64 {
        var ts = timestamp;
        const max_iterations = 60 * 60 * 24 * 366; // Max 1 year ahead

        var iterations: usize = 0;
        while (iterations < max_iterations) : (iterations += 1) {
            ts += 60; // Check every minute
            if (self.matches(ts)) return ts;
        }

        return 0; // No match found
    }

    /// Validate cron expression
    pub fn isValid(self: *const Self) bool {
        var has_minute = false;
        var has_hour = false;
        var has_day_of_month = false;
        var has_month = false;
        var has_day_of_week = false;

        for (self.minutes) |v| { if (v) has_minute = true; }
        for (self.hours) |v| { if (v) has_hour = true; }
        for (self.days_of_month) |v| { if (v) has_day_of_month = true; }
        for (self.months) |v| { if (v) has_month = true; }
        for (self.days_of_week) |v| { if (v) has_day_of_week = true; }

        return has_minute and has_hour and has_day_of_month and has_month and has_day_of_week;
    }

    /// Format cron expression as string
    pub fn format(self: *const Self, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);

        try self.formatField(&buf, allocator, &self.minutes);
        try buf.append(allocator, ' ');
        try self.formatField(&buf, allocator, &self.hours);
        try buf.append(allocator, ' ');
        try self.formatField(&buf, allocator, &self.days_of_month);
        try buf.append(allocator, ' ');
        try self.formatField(&buf, allocator, &self.months);
        try buf.append(allocator, ' ');
        try self.formatField(&buf, allocator, &self.days_of_week);

        return buf.toOwnedSlice(allocator);
    }

    fn formatField(self: *Self, buf: *std.ArrayList(u8), allocator: std.mem.Allocator, field: []const bool) !void {
        _ = self;
        var first = true;
        var i: usize = 0;
        while (i < field.len) : (i += 1) {
            if (field[i]) {
                if (!first) try buf.append(allocator, ',');
                try std.fmt.formatInt(i, 10, .lower, buf.writer(allocator));
                first = false;
            }
        }
        if (first) try buf.append(allocator, '*');
    }
};

/// Cron job definition
pub const CronJob = struct {
    name: []const u8,
    schedule: CronExpression,
    schedule_str: []const u8,
    task: *const fn () void,
    last_run: i64,
    next_run: i64,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name: []const u8, cron_expr: []const u8, task: *const fn () void) !Self {
        const parsed = try CronExpression.parse(allocator, cron_expr);

        const now = TimeKit.now();
        const next_run = parsed.nextRun(now);

        return Self{
            .name = try allocator.dupe(u8, name),
            .schedule = parsed,
            .schedule_str = cron_expr,
            .task = task,
            .last_run = 0,
            .next_run = next_run,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
    }

    /// Check if job should run now
    pub fn shouldRun(self: *Self) bool {
        const now = TimeKit.now();
        return now >= self.next_run;
    }

    /// Execute the job
    pub fn run(self: *Self) void {
        const now = TimeKit.now();
        self.last_run = now;
        self.next_run = self.schedule.nextRun(now);
        self.task();
    }
};

/// Cron plugin for ZFinal
pub const CronPlugin = struct {
    jobs: std.ArrayList(CronJob),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .jobs = std.ArrayList(CronJob).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.jobs.items) |*job| {
            job.deinit();
        }
        self.jobs.deinit(self.allocator);
    }

    /// Schedule a new cron job
    pub fn schedule(self: *Self, name: []const u8, cron_expr: []const u8, task: *const fn () void) !void {
        const parsed = try CronExpression.parse(self.allocator, cron_expr);

        const now = TimeKit.now();
        const next_run = parsed.nextRun(now);

        const job = CronJob{
            .name = try self.allocator.dupe(u8, name),
            .schedule = parsed,
            .schedule_str = cron_expr,
            .task = task,
            .last_run = 0,
            .next_run = next_run,
            .allocator = self.allocator,
        };

        try self.jobs.append(job);
    }

    /// Remove a job by name
    pub fn remove(self: *Self, name: []const u8) !void {
        for (self.jobs.items) |job| {
            if (std.mem.eql(u8, job.name, name)) {
                const idx = std.mem.indexOfScalar(*CronJob, self.jobs.items, &job).?;
                _ = self.jobs.swapRemove(idx);
                return;
            }
        }
        return error.JobNotFound;
    }

    /// Get next job to run
    pub fn getNextJob(self: *Self) ?*CronJob {
        var earliest: ?*CronJob = null;
        var earliest_time: i64 = std.math.maxInt(i64);

        for (self.jobs.items) |*job| {
            if (job.next_run < earliest_time) {
                earliest_time = job.next_run;
                earliest = job;
            }
        }

        return earliest;
    }

    /// Check and run due jobs
    pub fn tick(self: *Self) void {
        for (self.jobs.items) |*job| {
            if (job.shouldRun()) {
                job.run();
            }
        }
    }
};

test "cron expression parse - any" {
    const allocator = std.testing.allocator;
    const cron = try CronExpression.parse(allocator, "* * * * *");

    // All minutes should be set (0-59)
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        try std.testing.expect(cron.minutes[i]);
    }
    // All hours should be set (0-23)
    i = 0;
    while (i < 24) : (i += 1) {
        try std.testing.expect(cron.hours[i]);
    }
}

test "cron expression parse - specific" {
    const allocator = std.testing.allocator;
    const cron = try CronExpression.parse(allocator, "30 14 * * *");

    try std.testing.expect(cron.minutes[30]);
    try std.testing.expect(cron.hours[14]);
}

test "cron expression parse - step" {
    const allocator = std.testing.allocator;
    const cron = try CronExpression.parse(allocator, "*/15 * * * *");

    try std.testing.expect(cron.minutes[0]);
    try std.testing.expect(cron.minutes[15]);
    try std.testing.expect(cron.minutes[30]);
    try std.testing.expect(cron.minutes[45]);
}

test "cron expression parse - range" {
    const allocator = std.testing.allocator;
    const cron = try CronExpression.parse(allocator, "0 9-17 * * 1-5");

    try std.testing.expect(cron.minutes[0]);
    try std.testing.expect(cron.hours[9]);
    try std.testing.expect(cron.hours[12]);
    try std.testing.expect(cron.hours[17]);
    try std.testing.expect(cron.days_of_week[1]);
    try std.testing.expect(cron.days_of_week[5]);
}

test "cron expression parse - list" {
    const allocator = std.testing.allocator;
    const cron = try CronExpression.parse(allocator, "0,30 * * * *");

    try std.testing.expect(cron.minutes[0]);
    try std.testing.expect(cron.minutes[30]);
}

test "cron expression invalid" {
    const allocator = std.testing.allocator;
    const result = CronExpression.parse(allocator, "invalid");
    try std.testing.expectError(error.InvalidCronExpression, result);
}