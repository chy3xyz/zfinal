const std = @import("std");
const Router = @import("router.zig").Router;
const HttpMethod = @import("router.zig").HttpMethod;
const Server = @import("server.zig").Server;
const Handler = @import("router.zig").Handler;
const Interceptor = @import("../interceptor/interceptor.zig").Interceptor;
const InterceptorChain = @import("../interceptor/interceptor.zig").InterceptorChain;

const Plugin = @import("../plugin/plugin.zig").Plugin;
const PluginManager = @import("../plugin/plugin.zig").PluginManager;

pub const ZFinal = struct {
    allocator: std.mem.Allocator,
    router: Router,
    plugin_manager: PluginManager,
    port: u16,

    pub fn init(allocator: std.mem.Allocator) ZFinal {
        return ZFinal{
            .allocator = allocator,
            .router = Router.init(allocator),
            .plugin_manager = PluginManager.init(allocator),
            .port = 8080,
        };
    }

    pub fn deinit(self: *ZFinal) void {
        self.plugin_manager.stopAll() catch |err| {
            std.debug.print("Error stopping plugins: {}\n", .{err});
        };
        self.plugin_manager.deinit();
        self.router.deinit();
    }

    pub fn setPort(self: *ZFinal, port: u16) void {
        self.port = port;
    }

    pub fn addPlugin(self: *ZFinal, plugin: Plugin) !void {
        try self.plugin_manager.add(plugin);
    }

    pub fn addRoute(self: *ZFinal, path: []const u8, handler: Handler) !void {
        try self.router.add(path, handler);
    }

    /// Add route with specific interceptors
    pub fn addRouteWithInterceptors(self: *ZFinal, path: []const u8, handler: Handler, interceptors: InterceptorChain) !void {
        try self.router.addWithInterceptors(path, handler, interceptors);
    }

    /// Add global interceptor (applies to all routes)
    pub fn addGlobalInterceptor(self: *ZFinal, interceptor: Interceptor) !void {
        try self.router.global_interceptors.add(interceptor);
    }

    // === RESTful Methods ===

    /// Add GET route
    pub fn get(self: *ZFinal, path: []const u8, handler: Handler) !void {
        try self.router.addWithMethod(path, .GET, handler);
    }
    pub fn getWithInterceptors(self: *ZFinal, path: []const u8, handler: Handler, interceptors: []const Interceptor) !void {
        var chain = InterceptorChain.init(self.allocator);
        for (interceptors) |i| try chain.add(i);
        try self.router.addWithMethodAndInterceptors(path, .GET, handler, chain);
    }

    /// Add POST route
    pub fn post(self: *ZFinal, path: []const u8, handler: Handler) !void {
        try self.router.addWithMethod(path, .POST, handler);
    }
    pub fn postWithInterceptors(self: *ZFinal, path: []const u8, handler: Handler, interceptors: []const Interceptor) !void {
        var chain = InterceptorChain.init(self.allocator);
        for (interceptors) |i| try chain.add(i);
        try self.router.addWithMethodAndInterceptors(path, .POST, handler, chain);
    }

    /// Add PUT route
    pub fn put(self: *ZFinal, path: []const u8, handler: Handler) !void {
        try self.router.addWithMethod(path, .PUT, handler);
    }
    pub fn putWithInterceptors(self: *ZFinal, path: []const u8, handler: Handler, interceptors: []const Interceptor) !void {
        var chain = InterceptorChain.init(self.allocator);
        for (interceptors) |i| try chain.add(i);
        try self.router.addWithMethodAndInterceptors(path, .PUT, handler, chain);
    }

    /// Add DELETE route
    pub fn delete(self: *ZFinal, path: []const u8, handler: Handler) !void {
        try self.router.addWithMethod(path, .DELETE, handler);
    }
    pub fn deleteWithInterceptors(self: *ZFinal, path: []const u8, handler: Handler, interceptors: []const Interceptor) !void {
        var chain = InterceptorChain.init(self.allocator);
        for (interceptors) |i| try chain.add(i);
        try self.router.addWithMethodAndInterceptors(path, .DELETE, handler, chain);
    }

    /// Add PATCH route
    pub fn patch(self: *ZFinal, path: []const u8, handler: Handler) !void {
        try self.router.addWithMethod(path, .PATCH, handler);
    }
    pub fn patchWithInterceptors(self: *ZFinal, path: []const u8, handler: Handler, interceptors: []const Interceptor) !void {
        var chain = InterceptorChain.init(self.allocator);
        for (interceptors) |i| try chain.add(i);
        try self.router.addWithMethodAndInterceptors(path, .PATCH, handler, chain);
    }

    pub fn start(self: *ZFinal) !void {
        // Start all plugins
        try self.plugin_manager.startAll();

        var server = try Server.init(self.allocator, &self.router, self.port);
        try server.start();
    }
};

/// Route group for organizing routes with common prefix
pub const RouteGroup = struct {
    app: *ZFinal,
    prefix: []const u8,
    interceptors: InterceptorChain,

    pub fn init(app: *ZFinal, prefix: []const u8) RouteGroup {
        return RouteGroup{
            .app = app,
            .prefix = prefix,
            .interceptors = InterceptorChain.init(app.allocator),
        };
    }

    pub fn deinit(self: *RouteGroup) void {
        self.interceptors.deinit();
    }

    /// Add interceptor to this group
    pub fn addInterceptor(self: *RouteGroup, interceptor: Interceptor) !void {
        try self.interceptors.add(interceptor);
    }

    fn buildPath(self: *RouteGroup, path: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.prefix, path });
    }

    pub fn get(self: *RouteGroup, path: []const u8, handler: Handler) !void {
        const full_path = try self.buildPath(path, self.app.allocator);
        defer self.app.allocator.free(full_path);
        try self.app.get(full_path, handler);
    }

    pub fn post(self: *RouteGroup, path: []const u8, handler: Handler) !void {
        const full_path = try self.buildPath(path, self.app.allocator);
        defer self.app.allocator.free(full_path);
        try self.app.post(full_path, handler);
    }

    pub fn put(self: *RouteGroup, path: []const u8, handler: Handler) !void {
        const full_path = try self.buildPath(path, self.app.allocator);
        defer self.app.allocator.free(full_path);
        try self.app.put(full_path, handler);
    }

    pub fn delete(self: *RouteGroup, path: []const u8, handler: Handler) !void {
        const full_path = try self.buildPath(path, self.app.allocator);
        defer self.app.allocator.free(full_path);
        try self.app.delete(full_path, handler);
    }
};
