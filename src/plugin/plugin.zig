const std = @import("std");

/// Plugin 接口
pub const Plugin = struct {
    name: []const u8,
    vtable: *const VTable,
    context: *anyopaque,

    pub const VTable = struct {
        start: *const fn (ctx: *anyopaque) anyerror!void,
        stop: *const fn (ctx: *anyopaque) anyerror!void,
    };

    pub fn start(self: *Plugin) !void {
        try self.vtable.start(self.context);
    }

    pub fn stop(self: *Plugin) !void {
        try self.vtable.stop(self.context);
    }
};

/// Plugin 管理器
pub const PluginManager = struct {
    plugins: std.ArrayList(Plugin),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PluginManager {
        return PluginManager{
            .plugins = std.ArrayList(Plugin).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PluginManager) void {
        self.plugins.deinit(self.allocator);
    }

    /// 添加插件
    pub fn add(self: *PluginManager, plugin: Plugin) !void {
        try self.plugins.append(self.allocator, plugin);
    }

    /// 启动所有插件
    pub fn startAll(self: *PluginManager) !void {
        for (self.plugins.items) |*plugin| {
            std.debug.print("Starting plugin: {s}\n", .{plugin.name});
            try plugin.start();
        }
    }

    /// 停止所有插件
    pub fn stopAll(self: *PluginManager) !void {
        for (self.plugins.items) |*plugin| {
            std.debug.print("Stopping plugin: {s}\n", .{plugin.name});
            try plugin.stop();
        }
    }

    /// 获取插件
    pub fn get(self: *PluginManager, name: []const u8) ?*Plugin {
        for (self.plugins.items) |*plugin| {
            if (std.mem.eql(u8, plugin.name, name)) {
                return plugin;
            }
        }
        return null;
    }
};

test "plugin manager" {
    const allocator = std.testing.allocator;

    var manager = PluginManager.init(allocator);
    defer manager.deinit();

    // 测试添加和获取插件
    const TestPluginContext = struct {
        started: bool = false,
        stopped: bool = false,
    };

    var ctx = TestPluginContext{};

    const vtable = Plugin.VTable{
        .start = struct {
            fn start(context: *anyopaque) !void {
                const c: *TestPluginContext = @ptrCast(@alignCast(context));
                c.started = true;
            }
        }.start,
        .stop = struct {
            fn stop(context: *anyopaque) !void {
                const c: *TestPluginContext = @ptrCast(@alignCast(context));
                c.stopped = true;
            }
        }.stop,
    };

    const plugin = Plugin{
        .name = "test",
        .vtable = &vtable,
        .context = &ctx,
    };

    try manager.add(plugin);
    try manager.startAll();

    try std.testing.expect(ctx.started);
}
