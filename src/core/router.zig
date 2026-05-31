const std = @import("std");
const Context = @import("context.zig").Context;
const InterceptorChain = @import("../interceptor/interceptor.zig").InterceptorChain;

pub const Handler = *const fn (ctx: *Context) anyerror!void;

/// HTTP 方法枚举
pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
    ANY, // 匹配所有方法

    pub fn fromString(method: []const u8) ?HttpMethod {
        if (std.mem.eql(u8, method, "GET")) return .GET;
        if (std.mem.eql(u8, method, "POST")) return .POST;
        if (std.mem.eql(u8, method, "PUT")) return .PUT;
        if (std.mem.eql(u8, method, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, method, "PATCH")) return .PATCH;
        if (std.mem.eql(u8, method, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, method, "OPTIONS")) return .OPTIONS;
        return null;
    }
};

/// 路由段类型
const SegmentType = enum {
    static,
    param,
};

/// 路由段
const Segment = struct {
    type: SegmentType,
    value: []const u8,
};

/// 路由定义
pub const Route = struct {
    pattern: []const u8, // 路径模式，如 "/users/:id"
    method: HttpMethod, // HTTP 方法
    handler: Handler,
    interceptors: InterceptorChain,
    segments: []Segment, // 预解析的路由段
    param_names: [][]const u8, // 参数名列表

    /// 检查路径是否匹配此路由
    pub fn matches(self: *const Route, path: []const u8, method: HttpMethod) bool {
        // 方法必须匹配
        if (self.method != .ANY and self.method != method) return false;

        // 快速路径：如果没有参数，直接比较
        if (self.param_names.len == 0) {
            return std.mem.eql(u8, self.pattern, path);
        }

        // 优化后的匹配逻辑
        var path_it = std.mem.splitScalar(u8, path, '/');

        // 跳过第一个空段（因为路径以 / 开头）
        if (path.len > 0 and path[0] == '/') {
            _ = path_it.next();
        }

        for (self.segments) |segment| {
            const path_part = path_it.next() orelse return false;

            switch (segment.type) {
                .static => {
                    if (!std.mem.eql(u8, segment.value, path_part)) return false;
                },
                .param => {
                    // 参数匹配任意非空值
                    if (path_part.len == 0) return false;
                },
            }
        }

        // 确保路径没有剩余部分
        return path_it.next() == null;
    }

    /// 提取路径参数
    pub fn extractParams(self: *const Route, path: []const u8, allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
        var params = std.StringHashMap([]const u8).init(allocator);
        if (self.param_names.len == 0) return params;

        var path_it = std.mem.splitScalar(u8, path, '/');
        if (path.len > 0 and path[0] == '/') {
            _ = path_it.next();
        }

        for (self.segments) |segment| {
            const path_part = path_it.next() orelse break;

            if (segment.type == .param) {
                try params.put(segment.value, path_part);
            }
        }

        return params;
    }
};

/// 路由器
pub const Router = struct {
    routes: std.ArrayList(Route),
    /// HashMap fast path for static routes: "{method}:{path}" → route index.
    /// Parameterized routes fall back to linear scan.
    static_routes: std.StringHashMap(usize),
    global_interceptors: InterceptorChain,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Router {
        return Router{
            .routes = std.ArrayList(Route).empty,
            .static_routes = std.StringHashMap(usize).init(allocator),
            .global_interceptors = InterceptorChain.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Router) void {
        for (self.routes.items) |*route| {
            self.allocator.free(route.pattern);
            route.interceptors.deinit();
            self.allocator.free(route.segments);
            self.allocator.free(route.param_names);
        }
        self.routes.deinit(self.allocator);
        // Free owned hashmap keys
        var key_it = self.static_routes.keyIterator();
        while (key_it.next()) |key| self.allocator.free(key.*);
        self.static_routes.deinit();
        self.global_interceptors.deinit();
        self.* = undefined;
    }

    /// 添加路由（任意 HTTP 方法）
    pub fn add(self: *Router, path: []const u8, handler: Handler) !void {
        try self.addWithMethod(path, .ANY, handler);
    }

    /// 添加指定 HTTP 方法的路由
    pub fn addWithMethod(self: *Router, path: []const u8, method: HttpMethod, handler: Handler) !void {
        // 解析路由段和参数名
        const parsed = try parseRoute(path, self.allocator);

        // Dupe path so Route owns it — caller may free the original
        const owned_path = try self.allocator.dupe(u8, path);

        const route = Route{
            .pattern = owned_path,
            .method = method,
            .handler = handler,
            .interceptors = InterceptorChain.init(self.allocator),
            .segments = parsed.segments,
            .param_names = parsed.param_names,
        };

        try self.routes.append(self.allocator, route);
    }

    /// 添加带拦截器的路由
    pub fn addWithInterceptors(self: *Router, path: []const u8, handler: Handler, interceptors: InterceptorChain) !void {
        try self.addWithMethodAndInterceptors(path, .ANY, handler, interceptors);
    }

    /// 添加指定方法和带拦截器的路由
    pub fn addWithMethodAndInterceptors(self: *Router, path: []const u8, method: HttpMethod, handler: Handler, interceptors: InterceptorChain) !void {
        const parsed = try parseRoute(path, self.allocator);
        errdefer {
            self.allocator.free(parsed.segments);
            self.allocator.free(parsed.param_names);
        }

        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        const route = Route{
            .pattern = owned_path,
            .method = method,
            .handler = handler,
            .interceptors = interceptors,
            .segments = parsed.segments,
            .param_names = parsed.param_names,
        };

        try self.routes.append(self.allocator, route);

        // O(1) fast path: index static routes (no params) by "{method}:{path}"
        if (parsed.param_names.len == 0) {
            var key_buf: [128]u8 = undefined;
            const key = staticRouteKey(method, owned_path, &key_buf);
            const key_owned = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(key_owned);
            try self.static_routes.put(key_owned, self.routes.items.len - 1);
        }
    }

    /// Build the hashmap lookup key for a method + path combination.
    /// Writes into buf, returns the populated slice. If too long for the buffer,
    /// returns only the path portion (hashmap lookup will miss, falling back to linear scan).
    fn staticRouteKey(method: HttpMethod, path: []const u8, buf: *[128]u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}:{s}", .{ @tagName(method), path }) catch path;
    }

    /// 查找匹配的路由
    pub fn match(self: *Router, path: []const u8, method: HttpMethod) ?*Route {
        // O(1) fast path for exact-match static routes
        var key_buf: [128]u8 = undefined;
        const method_key = staticRouteKey(method, path, &key_buf);
        if (self.static_routes.get(method_key)) |idx| {
            return &self.routes.items[idx];
        }
        // Also try ANY-method static routes
        const any_key = staticRouteKey(.ANY, path, &key_buf);
        if (self.static_routes.get(any_key)) |idx| {
            return &self.routes.items[idx];
        }
        // Fall back to O(n) linear scan for parameterized routes
        for (self.routes.items) |*route| {
            if (route.matches(path, method)) {
                return route;
            }
        }
        return null;
    }

    /// 执行路由处理
    pub fn execute(self: *Router, path: []const u8, method: HttpMethod, ctx: *Context) !void {
        if (self.match(path, method)) |route| {
            // 提取路径参数
            if (route.param_names.len > 0) {
                ctx.path_params = try route.extractParams(path, self.allocator);
            }

            // 执行拦截器链
            if (self.global_interceptors.interceptors.items.len > 0 or route.interceptors.interceptors.items.len > 0) {
                var combined = InterceptorChain.init(self.allocator);
                defer combined.deinit();

                // Pre-allocate to avoid reallocation during appends
                const total_count = self.global_interceptors.interceptors.items.len + route.interceptors.interceptors.items.len;
                try combined.interceptors.ensureTotalCapacity(self.allocator, total_count);

                // 添加全局拦截器
                for (self.global_interceptors.interceptors.items) |interceptor| {
                    combined.interceptors.appendAssumeCapacity(interceptor);
                }

                // 添加路由特定拦截器
                for (route.interceptors.interceptors.items) |interceptor| {
                    combined.interceptors.appendAssumeCapacity(interceptor);
                }

                try combined.execute(ctx, route.handler);
            } else {
                try route.handler(ctx);
            }
        } else {
            // Route not matched — still run global interceptors (e.g. CORS preflight)
            for (self.global_interceptors.interceptors.items) |interceptor| {
                if (interceptor.before) |before| {
                    if (!(try before(ctx))) return;
                }
            }
            ctx.res_status = .not_found;
            try ctx.renderText("404 Not Found");
        }
    }
};

const ParsedRoute = struct {
    segments: []Segment,
    param_names: [][]const u8,
};

/// 解析路由模式
fn parseRoute(path: []const u8, allocator: std.mem.Allocator) !ParsedRoute {
    var segments = std.ArrayList(Segment).empty;
    var param_names = std.ArrayList([]const u8).empty;

    var parts = std.mem.splitScalar(u8, path, '/');

    // 跳过第一个空部分（如果路径以 / 开头）
    if (path.len > 0 and path[0] == '/') {
        _ = parts.next();
    }

    while (parts.next()) |part| {
        if (part.len > 0 and part[0] == ':') {
            const name = part[1..];
            try segments.append(allocator, .{ .type = .param, .value = name });
            try param_names.append(allocator, name);
        } else {
            try segments.append(allocator, .{ .type = .static, .value = part });
        }
    }

    return ParsedRoute{
        .segments = try segments.toOwnedSlice(allocator),
        .param_names = try param_names.toOwnedSlice(allocator),
    };
}

test "path parameter parsing" {
    const allocator = std.testing.allocator;

    const parsed = try parseRoute("/users/:id/posts/:post_id", allocator);
    defer allocator.free(parsed.segments);
    defer allocator.free(parsed.param_names);

    try std.testing.expectEqual(@as(usize, 2), parsed.param_names.len);
    try std.testing.expectEqualStrings("id", parsed.param_names[0]);
    try std.testing.expectEqualStrings("post_id", parsed.param_names[1]);

    // std.debug.print("Segments len: {d}\n", .{parsed.segments.len});
    // for (parsed.segments) |seg| {
    //    std.debug.print("Segment: {s} ({})\n", .{seg.value, seg.type});
    // }

    try std.testing.expectEqual(@as(usize, 4), parsed.segments.len);
    try std.testing.expect(parsed.segments[0].type == .static); // users
    try std.testing.expect(parsed.segments[1].type == .param); // :id
}

test "route static matching" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    // Dummy handler
    const h = struct { fn f(_: *Context) !void {} }.f;
    try router.addWithMethod("/api/health", .GET, h);
    try router.addWithMethod("/api/users", .POST, h);

    // Exact match
    try std.testing.expect(router.match("/api/health", .GET) != null);
    try std.testing.expect(router.match("/api/users", .POST) != null);

    // Method mismatch
    try std.testing.expect(router.match("/api/health", .POST) == null);
    try std.testing.expect(router.match("/api/users", .GET) == null);

    // Path mismatch
    try std.testing.expect(router.match("/api/unknown", .GET) == null);
}

test "route parameter matching" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const h = struct { fn f(_: *Context) !void {} }.f;
    try router.addWithMethod("/users/:id", .GET, h);
    try router.addWithMethod("/users/:id/posts/:post_id", .GET, h);

    // Parameterized paths match
    try std.testing.expect(router.match("/users/42", .GET) != null);
    try std.testing.expect(router.match("/users/abc", .GET) != null);
    try std.testing.expect(router.match("/users/42/posts/7", .GET) != null);

    // Empty param should not match
    try std.testing.expect(router.match("/users//", .GET) == null);
    try std.testing.expect(router.match("/users//posts/7", .GET) == null);

    // Extra path segments should not match
    try std.testing.expect(router.match("/users/42/extra", .GET) == null);
}

test "route param extraction" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const h = struct { fn f(_: *Context) !void {} }.f;
    try router.addWithMethod("/users/:id/posts/:post_id", .GET, h);

    const route = router.match("/users/42/posts/7", .GET).?;
    var params = try route.extractParams("/users/42/posts/7", allocator);
    defer params.deinit();

    try std.testing.expectEqualStrings("42", params.get("id").?);
    try std.testing.expectEqualStrings("7", params.get("post_id").?);
}

test "route any method matching" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const h = struct { fn f(_: *Context) !void {} }.f;
    try router.add("/api/any", h); // .ANY method

    try std.testing.expect(router.match("/api/any", .GET) != null);
    try std.testing.expect(router.match("/api/any", .POST) != null);
    try std.testing.expect(router.match("/api/any", .DELETE) != null);
}

test "route registration order priority" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const h1 = struct { fn f(_: *Context) !void {} }.f;
    const h2 = struct { fn f(_: *Context) !void {} }.f;
    try router.addWithMethod("/api/data", .GET, h1);
    try router.addWithMethod("/api/data", .GET, h2); // duplicate, both stored

    // First registered route matches (linear scan)
    const route = router.match("/api/data", .GET).?;
    // Both registered — priority is first-match
    try std.testing.expect(route.handler == h1);
}
