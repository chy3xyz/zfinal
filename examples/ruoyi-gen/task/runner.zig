const std = @import("std");

pub const Task = struct {
    name: []const u8,
    /// Cron expression like "0 */5 * * *" or "fixed:300" for 300-second interval.
    schedule: []const u8,
    run: *const fn () anyerror!void,
};

var tasks: std.ArrayList(Task) = undefined;
var started: bool = false;

pub fn init(allocator: std.mem.Allocator) void {
    tasks = std.ArrayList(Task).init(allocator);
}

pub fn register(task: Task) !void {
    try tasks.append(task);
}

/// Start all registered tasks. Each task runs on its own schedule.
pub fn start(io: std.Io) !void {
    if (started) return;
    started = true;
    for (tasks.items) |task| {
        if (std.mem.startsWith(u8, task.schedule, "fixed:")) {
            const sec_str = task.schedule["fixed:".len..];
            const sec = std.fmt.parseInt(u64, sec_str, 10) catch 60;
            _ = sec; // TODO: spawn timer
        }
        _ = task;
        _ = io;
    }
}

pub fn deinit() void {
    tasks.deinit();
}