//! Skill / Tool registry for business AI agents (OpenAI function-calling shape).

const std = @import("std");
const time_util = @import("time_util.zig");

pub const Param = struct {
    name: []const u8,
    type: Type,
    description: []const u8,
    required: bool = false,

    pub const Type = enum { string, number, boolean, array, object };
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const Param,
    timeout_ms: ?u64 = null,
    handler: *const fn (ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value,
};

pub const SkillContext = struct {
    allocator: std.mem.Allocator,
    tenant_id: ?i64 = null,
    user_id: ?i64 = null,
    backend_ptr: ?*anyopaque = null,
    run_id: ?[]const u8 = null,
    userdata: ?*anyopaque = null,
    deadline_ms: ?i64 = null,

    pub fn expired(self: *const SkillContext) bool {
        const d = self.deadline_ms orelse return false;
        return time_util.nowMillis() > d;
    }

    pub fn checkDeadline(self: *const SkillContext) !void {
        if (self.expired()) return error.ToolTimeout;
    }
};

pub const DispatchOpts = struct {
    allowlist: ?[]const []const u8 = null,
    timeout_ms: ?u64 = null,
};

/// Free a dispatch result produced by a skill handler. Convention: handlers
/// own every string in the result (dupe with SkillContext.allocator).
pub fn freeValue(allocator: std.mem.Allocator, v: std.json.Value) void {
    var value = v;
    switch (value) {
        .string => |s| allocator.free(s),
        .array => |*arr| {
            for (arr.items) |item| freeValue(allocator, item);
            arr.deinit();
        },
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeValue(allocator, entry.value_ptr.*);
            }
            obj.deinit(allocator);
        },
        else => {},
    }
}

pub const SkillRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    tools: std.StringHashMap(Tool),
    mutex: std.Io.Mutex,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .tools = std.StringHashMap(Tool).init(allocator),
            .mutex = .init,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.tools.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.parameters) |p| self.allocator.free(p.name);
            self.allocator.free(entry.value_ptr.parameters);
        }
        self.tools.deinit();
        self.* = undefined;
    }

    pub fn register(self: *Self, tool: Tool) !void {
        self.mutex.lock(self.io) catch return error.RegistryLockFailed;
        defer self.mutex.unlock(self.io);

        const key = try self.allocator.dupe(u8, tool.name);
        errdefer self.allocator.free(key);
        const params = try self.allocator.alloc(Param, tool.parameters.len);
        errdefer self.allocator.free(params);
        for (tool.parameters, 0..) |p, i| {
            params[i] = .{
                .name = try self.allocator.dupe(u8, p.name),
                .type = p.type,
                .description = p.description,
                .required = p.required,
            };
        }
        const gop = try self.tools.getOrPut(key);
        if (gop.found_existing) {
            self.allocator.free(gop.key_ptr.*);
            for (gop.value_ptr.parameters) |p| self.allocator.free(p.name);
            self.allocator.free(gop.value_ptr.parameters);
            gop.key_ptr.* = key;
        }
        gop.value_ptr.* = .{
            .name = key,
            .description = tool.description,
            .parameters = params,
            .timeout_ms = tool.timeout_ms,
            .handler = tool.handler,
        };
    }

    pub fn get(self: *Self, name: []const u8) ?Tool {
        self.mutex.lock(self.io) catch return null;
        defer self.mutex.unlock(self.io);
        return self.tools.get(name);
    }

    pub fn count(self: *Self) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        return self.tools.count();
    }

    /// Fill `buf` with registered tool names (not owned). Returns count written.
    pub fn names(self: *Self, buf: [][]const u8) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        var n: usize = 0;
        var it = self.tools.iterator();
        while (it.next()) |entry| {
            if (n >= buf.len) break;
            buf[n] = entry.key_ptr.*;
            n += 1;
        }
        return n;
    }

    pub fn toOpenAiFunctionsAlloc(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock(self.io) catch return error.RegistryLockFailed;
        defer self.mutex.unlock(self.io);

        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try buf.append(allocator, '[');
        var first = true;
        var it = self.tools.iterator();
        while (it.next()) |entry| {
            const t = entry.value_ptr;
            if (!first) try buf.append(allocator, ',');
            first = false;
            try buf.print(allocator, "{{\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"description\":\"{s}\",\"parameters\":{{\"type\":\"object\",\"properties\":{{", .{ t.name, t.description });
            for (t.parameters, 0..) |p, pi| {
                if (pi > 0) try buf.append(allocator, ',');
                try buf.print(allocator, "\"{s}\":{{\"type\":\"{s}\",\"description\":\"{s}\"}}", .{ p.name, @tagName(p.type), p.description });
            }
            try buf.appendSlice(allocator, "},\"required\":[");
            var req_first = true;
            for (t.parameters) |p| {
                if (p.required) {
                    if (!req_first) try buf.append(allocator, ',');
                    req_first = false;
                    try buf.print(allocator, "\"{s}\"", .{p.name});
                }
            }
            try buf.appendSlice(allocator, "]}}}}");
        }
        try buf.append(allocator, ']');
        return try buf.toOwnedSlice(allocator);
    }

    pub fn validateArgs(tool: Tool, args: std.json.Value) !void {
        if (tool.parameters.len == 0) return;
        if (args == .null) return error.MissingToolArg;
        if (args != .object) return error.InvalidToolArgs;
        for (tool.parameters) |p| {
            if (p.required and args.object.get(p.name) == null) return error.MissingToolArg;
        }
    }

    pub fn dispatch(self: *Self, name: []const u8, ctx: *SkillContext, args: std.json.Value) !std.json.Value {
        return self.dispatchWith(name, ctx, args, .{});
    }

    pub fn dispatchAllowed(
        self: *Self,
        name: []const u8,
        ctx: *SkillContext,
        args: std.json.Value,
        allowlist: ?[]const []const u8,
    ) !std.json.Value {
        return self.dispatchWith(name, ctx, args, .{ .allowlist = allowlist });
    }

    pub fn dispatchWith(
        self: *Self,
        name: []const u8,
        ctx: *SkillContext,
        args: std.json.Value,
        opts: DispatchOpts,
    ) !std.json.Value {
        if (opts.allowlist) |al| {
            var ok = false;
            for (al) |n| {
                if (std.mem.eql(u8, n, name)) {
                    ok = true;
                    break;
                }
            }
            if (!ok) return error.ToolNotAllowed;
        }

        self.mutex.lock(self.io) catch return error.RegistryLockFailed;
        const tool = self.tools.get(name) orelse {
            self.mutex.unlock(self.io);
            return error.ToolNotFound;
        };
        try validateArgs(tool, args);
        const handler = tool.handler;
        const budget = opts.timeout_ms orelse tool.timeout_ms;
        self.mutex.unlock(self.io);

        const prev_deadline = ctx.deadline_ms;
        defer ctx.deadline_ms = prev_deadline;
        const started = time_util.nowMillis();
        if (budget) |ms| {
            ctx.deadline_ms = started + @as(i64, @intCast(ms));
        } else {
            ctx.deadline_ms = null;
        }

        const result = try handler(ctx, args);
        if (budget) |ms| {
            const elapsed: u64 = @intCast(@max(time_util.nowMillis() - started, 0));
            if (elapsed > ms) {
                freeValue(ctx.allocator, result);
                return error.ToolTimeout;
            }
        }
        try ctx.checkDeadline();
        return result;
    }
};

test "SkillRegistry register and dispatch" {
    const allocator = std.testing.allocator;
    var reg = SkillRegistry.init(allocator, std.testing.io);
    defer reg.deinit();

    try reg.register(.{
        .name = "ping",
        .description = "Returns pong",
        .parameters = &.{},
        .handler = struct {
            fn h(ctx: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
                return .{ .string = try ctx.allocator.dupe(u8, "pong") };
            }
        }.h,
    });

    try std.testing.expectEqual(@as(usize, 1), reg.count());
    var ctx = SkillContext{ .allocator = allocator };
    const result = try reg.dispatch("ping", &ctx, .null);
    defer freeValue(allocator, result);
    try std.testing.expectEqualStrings("pong", result.string);
}

test "SkillRegistry allowlist" {
    const allocator = std.testing.allocator;
    var reg = SkillRegistry.init(allocator, std.testing.io);
    defer reg.deinit();
    try reg.register(.{
        .name = "echo",
        .description = "echo",
        .parameters = &.{.{ .name = "text", .type = .string, .description = "t", .required = true }},
        .handler = struct {
            fn h(_: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                return args.object.get("text").?;
            }
        }.h,
    });
    var ctx = SkillContext{ .allocator = allocator };
    try std.testing.expectError(error.ToolNotAllowed, reg.dispatchAllowed("echo", &ctx, .null, &.{"other"}));
}
