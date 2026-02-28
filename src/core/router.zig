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
    global_interceptors: InterceptorChain,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Router {
        return Router{
            .routes = std.ArrayList(Route).init(allocator),
            .global_interceptors = InterceptorChain.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Router) void {
        for (self.routes.items) |*route| {
            route.interceptors.deinit();
            self.allocator.free(route.segments);
            self.allocator.free(route.param_names);
        }
        self.routes.deinit();
        self.global_interceptors.deinit();
    }

    /// 添加路由（任意 HTTP 方法）
    pub fn add(self: *Router, path: []const u8, handler: Handler) !void {
        try self.addWithMethod(path, .ANY, handler);
    }

    /// 添加指定 HTTP 方法的路由
    pub fn addWithMethod(self: *Router, path: []const u8, method: HttpMethod, handler: Handler) !void {
        // 解析路由段和参数名
        const parsed = try parseRoute(path, self.allocator);

        const route = Route{
            .pattern = path,
            .method = method,
            .handler = handler,
            .interceptors = InterceptorChain.init(self.allocator),
            .segments = parsed.segments,
            .param_names = parsed.param_names,
        };

        try self.routes.append(route);
    }

    /// 添加带拦截器的路由
    pub fn addWithInterceptors(self: *Router, path: []const u8, handler: Handler, interceptors: InterceptorChain) !void {
        try self.addWithMethodAndInterceptors(path, .ANY, handler, interceptors);
    }

    /// 添加指定方法和带拦截器的路由
    pub fn addWithMethodAndInterceptors(self: *Router, path: []const u8, method: HttpMethod, handler: Handler, interceptors: InterceptorChain) !void {
        const parsed = try parseRoute(path, self.allocator);

        const route = Route{
            .pattern = path,
            .method = method,
            .handler = handler,
            .interceptors = interceptors,
            .segments = parsed.segments,
            .param_names = parsed.param_names,
        };

        try self.routes.append(route);
    }

    /// 查找匹配的路由
    pub fn match(self: *Router, path: []const u8, method: HttpMethod) ?*Route {
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

                // 添加全局拦截器
                for (self.global_interceptors.interceptors.items) |interceptor| {
                    try combined.add(interceptor);
                }

                // 添加路由特定拦截器
                for (route.interceptors.interceptors.items) |interceptor| {
                    try combined.add(interceptor);
                }

                try combined.execute(ctx, route.handler);
            } else {
                try route.handler(ctx);
            }
        } else {
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
    var segments = std.ArrayList(Segment).init(allocator);
    var param_names = std.ArrayList([]const u8).init(allocator);

    var parts = std.mem.splitScalar(u8, path, '/');

    // 跳过第一个空部分（如果路径以 / 开头）
    if (path.len > 0 and path[0] == '/') {
        _ = parts.next();
    }

    while (parts.next()) |part| {
        if (part.len > 0 and part[0] == ':') {
            const name = part[1..];
            try segments.append(.{ .type = .param, .value = name });
            try param_names.append(name);
        } else {
            try segments.append(.{ .type = .static, .value = part });
        }
    }

    return ParsedRoute{
        .segments = try segments.toOwnedSlice(),
        .param_names = try param_names.toOwnedSlice(),
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
