//! Thin AI ⇄ CronPlugin bridge.
//!
//! Lets an Agent schedule **pre-registered named tasks** on cron expressions
//! via tool calls. The LLM only supplies a task name + cron expression — it
//! never provides code.

const std = @import("std");
const CronPlugin = @import("../plugin/cron.zig").CronPlugin;
const SkillRegistry = @import("skill.zig").SkillRegistry;
const SkillContext = @import("skill.zig").SkillContext;

fn putOwned(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: std.json.Value) !void {
    try obj.put(allocator, try allocator.dupe(u8, key), value);
}

/// A named, schedulable task the LLM may attach to a cron expression.
pub const ScheduledTask = struct {
    name: []const u8,
    description: []const u8,
    task: *const fn (*anyopaque) void,
    context: *anyopaque,
};

/// Capability bundle: CronPlugin + whitelist. Set
/// `SkillContext.userdata = &schedule_ctx` before dispatch.
pub const ScheduleCtx = struct {
    cron: *CronPlugin,
    tasks: []const ScheduledTask,
};

pub fn registerScheduleSkills(registry: *SkillRegistry) !void {
    try registry.register(.{
        .name = "list_schedulable_tasks",
        .description = "List tasks that can be scheduled and their descriptions",
        .parameters = &.{},
        .handler = struct {
            fn h(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try ctx.checkDeadline();
                _ = args;
                const sc: *ScheduleCtx = @ptrCast(@alignCast(ctx.userdata orelse return error.SchedulerNotConfigured));
                var out = std.json.ObjectMap{};
                var arr = std.json.Array.init(ctx.allocator);
                for (sc.tasks) |t| {
                    var obj = std.json.ObjectMap{};
                    try putOwned(&obj, ctx.allocator, "name", .{ .string = try ctx.allocator.dupe(u8, t.name) });
                    try putOwned(&obj, ctx.allocator, "description", .{ .string = try ctx.allocator.dupe(u8, t.description) });
                    try arr.append(.{ .object = obj });
                }
                try putOwned(&out, ctx.allocator, "tasks", .{ .array = arr });
                return .{ .object = out };
            }
        }.h,
    });

    try registry.register(.{
        .name = "schedule_job",
        .description = "Schedule a named task on a 5-field cron expression (minute hour day-of-month month day-of-week; e.g. '0 9 * * *' for 09:00 daily)",
        .parameters = &.{
            .{ .name = "task", .type = .string, .description = "Task name from list_schedulable_tasks", .required = true },
            .{ .name = "expr", .type = .string, .description = "Cron expression", .required = true },
        },
        .handler = struct {
            fn h(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try ctx.checkDeadline();
                const sc: *ScheduleCtx = @ptrCast(@alignCast(ctx.userdata orelse return error.SchedulerNotConfigured));
                if (args != .object) return error.InvalidArguments;
                const obj = args.object;
                const task_value = obj.get("task") orelse return error.InvalidArguments;
                const expr_value = obj.get("expr") orelse return error.InvalidArguments;
                if (task_value != .string or expr_value != .string) return error.InvalidArguments;

                var found: ?ScheduledTask = null;
                for (sc.tasks) |t| {
                    if (std.mem.eql(u8, t.name, task_value.string)) {
                        found = t;
                        break;
                    }
                }
                const entry = found orelse return error.TaskNotFound;

                try sc.cron.scheduleWith(task_value.string, expr_value.string, entry.task, entry.context);

                var out = std.json.ObjectMap{};
                try putOwned(&out, ctx.allocator, "ok", .{ .bool = true });
                try putOwned(&out, ctx.allocator, "job", .{ .string = try ctx.allocator.dupe(u8, task_value.string) });
                try putOwned(&out, ctx.allocator, "expr", .{ .string = try ctx.allocator.dupe(u8, expr_value.string) });
                return .{ .object = out };
            }
        }.h,
    });

    try registry.register(.{
        .name = "list_jobs",
        .description = "List jobs currently scheduled on the cron plugin",
        .parameters = &.{},
        .handler = struct {
            fn h(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try ctx.checkDeadline();
                _ = args;
                const sc: *ScheduleCtx = @ptrCast(@alignCast(ctx.userdata orelse return error.SchedulerNotConfigured));
                const names = try sc.cron.listJobNames(ctx.allocator);
                var arr = std.json.Array.init(ctx.allocator);
                for (names) |n| try arr.append(.{ .string = n });
                ctx.allocator.free(names);
                var out = std.json.ObjectMap{};
                try putOwned(&out, ctx.allocator, "jobs", .{ .array = arr });
                return .{ .object = out };
            }
        }.h,
    });

    try registry.register(.{
        .name = "cancel_job",
        .description = "Cancel a scheduled job by name",
        .parameters = &.{
            .{ .name = "job", .type = .string, .description = "Job name from list_jobs", .required = true },
        },
        .handler = struct {
            fn h(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try ctx.checkDeadline();
                const sc: *ScheduleCtx = @ptrCast(@alignCast(ctx.userdata orelse return error.SchedulerNotConfigured));
                if (args != .object) return error.InvalidArguments;
                const job_v = args.object.get("job") orelse return error.InvalidArguments;
                if (job_v != .string) return error.InvalidArguments;
                const removed = sc.cron.cancelJob(job_v.string);
                var out = std.json.ObjectMap{};
                try putOwned(&out, ctx.allocator, "ok", .{ .bool = true });
                try putOwned(&out, ctx.allocator, "removed", .{ .bool = removed });
                return .{ .object = out };
            }
        }.h,
    });
}

test "schedule skills list tasks and schedule a job that fires on tick" {
    const allocator = std.testing.allocator;
    var count: usize = 0;
    const T = struct {
        fn run(ptr: *anyopaque) void {
            const c: *usize = @ptrCast(@alignCast(ptr));
            c.* += 1;
        }
    };
    const tasks = [_]ScheduledTask{
        .{ .name = "ping", .description = "increment a counter", .task = T.run, .context = &count },
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cron = CronPlugin.init(allocator);
    defer cron.deinit();
    var sched_ctx = ScheduleCtx{ .cron = &cron, .tasks = &tasks };
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registerScheduleSkills(&registry);

    var ctx = SkillContext{ .allocator = a, .userdata = @ptrCast(&sched_ctx) };

    const list = try registry.dispatch("list_schedulable_tasks", &ctx, .{ .object = .{} });
    defer @import("skill.zig").freeValue(a, list);
    try std.testing.expect(list == .object);
    try std.testing.expectEqual(@as(usize, 1), list.object.get("tasks").?.array.items.len);
    try std.testing.expectEqualStrings("ping", list.object.get("tasks").?.array.items[0].object.get("name").?.string);

    var args_map = std.json.ObjectMap{};
    try args_map.put(a, try a.dupe(u8, "task"), .{ .string = "ping" });
    try args_map.put(a, try a.dupe(u8, "expr"), .{ .string = "* * * * *" });
    const res = try registry.dispatch("schedule_job", &ctx, .{ .object = args_map });
    defer @import("skill.zig").freeValue(a, res);
    try std.testing.expect(res.object.get("ok").?.bool);
    try std.testing.expectEqual(@as(usize, 1), cron.jobCount());

    // Force due so tick runs immediately.
    cron.jobs.items[0].next_run = 0;
    cron.tick();
    try std.testing.expectEqual(@as(usize, 1), count);

    const jobs = try registry.dispatch("list_jobs", &ctx, .{ .object = .{} });
    defer @import("skill.zig").freeValue(a, jobs);
    try std.testing.expectEqual(@as(usize, 1), jobs.object.get("jobs").?.array.items.len);

    var cancel_map = std.json.ObjectMap{};
    try cancel_map.put(a, try a.dupe(u8, "job"), .{ .string = "ping" });
    const cancelled = try registry.dispatch("cancel_job", &ctx, .{ .object = cancel_map });
    defer @import("skill.zig").freeValue(a, cancelled);
    try std.testing.expect(cancelled.object.get("removed").?.bool);
    try std.testing.expectEqual(@as(usize, 0), cron.jobCount());
}
