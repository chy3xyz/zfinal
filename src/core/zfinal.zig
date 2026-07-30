const std = @import("std");
const Router = @import("router.zig").Router;
const HttpMethod = @import("router.zig").HttpMethod;
const Server = @import("server.zig").Server;
const ServerConfig = @import("server.zig").ServerConfig;
const Handler = @import("router.zig").Handler;
const Metrics = @import("metrics.zig").Metrics;
const Interceptor = @import("../interceptor/interceptor.zig").Interceptor;
const InterceptorChain = @import("../interceptor/interceptor.zig").InterceptorChain;

const Plugin = @import("../plugin/plugin.zig").Plugin;
const PluginManager = @import("../plugin/plugin.zig").PluginManager;

/// ZFinal application — main entry point for building web servers.
/// Usage: `var app = zfinal.ZFinal.init(allocator); defer app.deinit();`
pub const ZFinal = struct {
    allocator: std.mem.Allocator,
    router: Router,
    plugin_manager: PluginManager,
    config: ServerConfig,
    /// Optional request metrics. When set, `dispatch` auto-records status classes.
    metrics: ?*Metrics = null,
    /// Typed app State (see `setState` / `Context.state`).
    app_state: @import("state.zig").Handle = .{},

    /// Initialize a new ZFinal application. Routes, plugins, and config
    /// are added before calling `start()`.
    pub fn init(allocator: std.mem.Allocator) ZFinal {
        return ZFinal{
            .allocator = allocator,
            .router = Router.init(allocator),
            .plugin_manager = PluginManager.init(allocator),
            .config = .{},
        };
    }

    /// Stop all plugins, deinitialize the router, and free all resources.
    /// Must be called exactly once after the server stops.
    pub fn deinit(self: *ZFinal) void {
        self.plugin_manager.stopAll();
        self.plugin_manager.deinit();
        self.router.deinit();
        self.* = undefined;
    }

    /// Set the HTTP listen port (default 8080).
    pub fn setPort(self: *ZFinal, port: u16) void {
        self.config.port = port;
    }

    /// Replace the entire server configuration.
    pub fn setConfig(self: *ZFinal, config: ServerConfig) void {
        self.config = config;
    }

    /// Attach shared Metrics so the core server auto-records connections/requests.
    pub fn setMetrics(self: *ZFinal, metrics: *Metrics) void {
        self.metrics = metrics;
    }

    /// Attach typed application State. Handlers read it via `ctx.state(T)`.
    /// `ptr` must outlive the server (typically a local in `main`).
    pub fn setState(self: *ZFinal, comptime T: type, ptr: *T) void {
        self.app_state.set(T, ptr);
    }

    /// SPA / custom 404 when no route matches (not used for 405).
    pub fn setFallback(self: *ZFinal, handler: Handler) !void {
        try self.router.setFallback(handler);
    }

    /// Register several module `routes.register` callbacks (Router::merge analogue).
    pub fn merge(self: *ZFinal, registers: []const *const fn (*ZFinal) anyerror!void) !void {
        for (registers) |reg| try reg(self);
    }

    /// Register a plugin. Plugins are started in registration order when
    /// `start()` is called and stopped in reverse order on `deinit()`.
    pub fn addPlugin(self: *ZFinal, plugin: Plugin) !void {
        try self.plugin_manager.add(plugin);
    }

    /// Add a route matching all HTTP methods.
    pub fn addRoute(self: *ZFinal, path: []const u8, handler: Handler) !void {
        try self.router.add(path, handler);
    }

    /// Add a route with method-specific interceptors.
    pub fn addRouteWithInterceptors(self: *ZFinal, path: []const u8, handler: Handler, interceptors: InterceptorChain) !void {
        try self.router.addWithInterceptors(path, handler, interceptors);
    }

    /// Add a global interceptor that runs before every route.
    pub fn addGlobalInterceptor(self: *ZFinal, interceptor: Interceptor) !void {
        try self.router.global_interceptors.add(interceptor);
    }

    // === RESTful route registration ===

    /// Register a GET route.
    pub fn get(self: *ZFinal, path: []const u8, handler: Handler) !void {
        try self.router.addWithMethod(path, .GET, handler);
    }
    /// Register a GET route with specific interceptors.
    pub fn getWithInterceptors(self: *ZFinal, path: []const u8, handler: Handler, interceptors: []const Interceptor) !void {
        var chain = InterceptorChain.init(self.allocator);
        for (interceptors) |i| try chain.add(i);
        try self.router.addWithMethodAndInterceptors(path, .GET, handler, chain);
    }

    /// Register a POST route.
    pub fn post(self: *ZFinal, path: []const u8, handler: Handler) !void {
        try self.router.addWithMethod(path, .POST, handler);
    }
    /// Register a POST route with specific interceptors.
    pub fn postWithInterceptors(self: *ZFinal, path: []const u8, handler: Handler, interceptors: []const Interceptor) !void {
        var chain = InterceptorChain.init(self.allocator);
        for (interceptors) |i| try chain.add(i);
        try self.router.addWithMethodAndInterceptors(path, .POST, handler, chain);
    }

    /// Register a PUT route.
    pub fn put(self: *ZFinal, path: []const u8, handler: Handler) !void {
        try self.router.addWithMethod(path, .PUT, handler);
    }
    /// Register a PUT route with specific interceptors.
    pub fn putWithInterceptors(self: *ZFinal, path: []const u8, handler: Handler, interceptors: []const Interceptor) !void {
        var chain = InterceptorChain.init(self.allocator);
        for (interceptors) |i| try chain.add(i);
        try self.router.addWithMethodAndInterceptors(path, .PUT, handler, chain);
    }

    /// Register a DELETE route.
    pub fn delete(self: *ZFinal, path: []const u8, handler: Handler) !void {
        try self.router.addWithMethod(path, .DELETE, handler);
    }
    /// Register a DELETE route with specific interceptors.
    pub fn deleteWithInterceptors(self: *ZFinal, path: []const u8, handler: Handler, interceptors: []const Interceptor) !void {
        var chain = InterceptorChain.init(self.allocator);
        for (interceptors) |i| try chain.add(i);
        try self.router.addWithMethodAndInterceptors(path, .DELETE, handler, chain);
    }

    /// Register a PATCH route.
    pub fn patch(self: *ZFinal, path: []const u8, handler: Handler) !void {
        try self.router.addWithMethod(path, .PATCH, handler);
    }
    /// Register a PATCH route with specific interceptors.
    pub fn patchWithInterceptors(self: *ZFinal, path: []const u8, handler: Handler, interceptors: []const Interceptor) !void {
        var chain = InterceptorChain.init(self.allocator);
        for (interceptors) |i| try chain.add(i);
        try self.router.addWithMethodAndInterceptors(path, .PATCH, handler, chain);
    }

    /// Start the HTTP server. Blocks until shutdown or fatal error.
    /// Automatically starts all registered plugins before accepting connections.
    pub fn start(self: *ZFinal) !void {
        try self.router.seal();
        try self.plugin_manager.startAll();
        var server = try Server.init(self.allocator, &self.router, self.config);
        server.metrics = self.metrics;
        server.app_state = self.app_state;
        try server.start();
    }

    /// API version prefix group (smart_routing). Same as `RouteGroup.init(self, prefix)`.
    pub fn mountApi(self: *ZFinal, prefix: []const u8) RouteGroup {
        return RouteGroup.init(self, prefix);
    }
};

/// Route group for organizing routes with common prefix and shared interceptors.
/// Usage: `var api = zfinal.RouteGroup.init(&app, "/api");`
pub const RouteGroup = struct {
    app: *ZFinal,
    prefix: []const u8,
    interceptors: InterceptorChain,

    /// Create a route group. Routes registered on this group are prefixed
    /// with `prefix` (e.g., `"/api"` → `"/api/users"`).
    pub fn init(app: *ZFinal, prefix: []const u8) RouteGroup {
        return RouteGroup{
            .app = app,
            .prefix = prefix,
            .interceptors = InterceptorChain.init(app.allocator),
        };
    }

    /// Free interceptor chain resources.
    pub fn deinit(self: *RouteGroup) void {
        self.interceptors.deinit();
    }

    /// Add an interceptor to this group (applies to all routes in the group).
    pub fn addInterceptor(self: *RouteGroup, interceptor: Interceptor) !void {
        try self.interceptors.add(interceptor);
    }

    fn buildPath(self: *RouteGroup, path: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.prefix, path });
    }

    fn register(self: *RouteGroup, method: HttpMethod, path: []const u8, handler: Handler) !void {
        const full_path = try self.buildPath(path, self.app.allocator);
        defer self.app.allocator.free(full_path);
        if (self.interceptors.interceptors.items.len == 0) {
            try self.app.router.addWithMethod(full_path, method, handler);
        } else {
            try self.app.router.addWithMethodAndInterceptors(
                full_path,
                method,
                handler,
                try cloneInterceptorChain(&self.interceptors),
            );
        }
    }

    fn cloneInterceptorChain(src: *const InterceptorChain) !InterceptorChain {
        var chain = InterceptorChain.init(src.allocator);
        errdefer chain.deinit();
        for (src.interceptors.items) |i| try chain.add(i);
        return chain;
    }

    /// Register a GET route with the group prefix.
    pub fn get(self: *RouteGroup, path: []const u8, handler: Handler) !void {
        try self.register(.GET, path, handler);
    }

    /// Register a POST route with the group prefix.
    pub fn post(self: *RouteGroup, path: []const u8, handler: Handler) !void {
        try self.register(.POST, path, handler);
    }

    /// Register a PUT route with the group prefix.
    pub fn put(self: *RouteGroup, path: []const u8, handler: Handler) !void {
        try self.register(.PUT, path, handler);
    }

    /// Register a PATCH route with the group prefix.
    pub fn patch(self: *RouteGroup, path: []const u8, handler: Handler) !void {
        try self.register(.PATCH, path, handler);
    }

    /// Register a DELETE route with the group prefix.
    pub fn delete(self: *RouteGroup, path: []const u8, handler: Handler) !void {
        try self.register(.DELETE, path, handler);
    }
};
