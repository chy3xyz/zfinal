const std = @import("std");
const Plugin = @import("plugin.zig").Plugin;

/// Cron 任务
pub const CronJob = struct {
    name: []const u8,
    schedule: []const u8, // Cron 表达式（简化版）
    task: *const fn () void,
    last_run: i64 = 0,
};

/// 定时任务插件
pub const CronPlugin = struct {
    jobs: std.ArrayList(CronJob),
    allocator: std.mem.Allocator,
    running: bool = false,
    thread: ?std.Thread = null,
    name: []const u8 = "cron",

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) CronPlugin {
        return CronPlugin{
            .jobs = std.ArrayList(CronJob).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop() catch {};
        self.jobs.deinit(self.allocator);
    }

    /// 添加定时任务
    pub fn schedule(self: *Self, name: []const u8, cron_expr: []const u8, task: *const fn () void) !void {
        const job = CronJob{
            .name = name,
            .schedule = cron_expr,
            .task = task,
        };
        try self.jobs.append(self.allocator, job);
    }

    /// 启动定时任务
    pub fn start(self: *Self) !void {
        if (self.running) return;

        self.running = true;
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    /// 停止定时任务
    pub fn stop(self: *Self) !void {
        if (!self.running) return;

        self.running = false;
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    /// 运行循环
    fn runLoop(self: *Self) void {
        while (self.running) {
            const now = std.time.timestamp();

            for (self.jobs.items) |*job| {
                // 简化版：每分钟检查一次
                if (now - job.last_run >= 60) {
                    std.debug.print("Running cron job: {s}\n", .{job.name});
                    job.task();
                    job.last_run = now;
                }
            }

            // 每秒检查一次
            std.time.sleep(1 * std.time.ns_per_s);
        }
    }

    // Plugin 接口实现
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

test "cron plugin basic" {
    const allocator = std.testing.allocator;

    var cron = CronPlugin.init(allocator);
    defer cron.deinit();

    const testTask = struct {
        fn task() void {
            // 测试任务
        }
    }.task;

    try cron.schedule("test_job", "* * * * *", testTask);
    try std.testing.expectEqual(@as(usize, 1), cron.jobs.items.len);
}
