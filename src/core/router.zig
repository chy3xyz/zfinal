const std = @import("std");
const Context = @import("context.zig").Context;
const InterceptorChain = @import("../interceptor/interceptor.zig").InterceptorChain;
const io_instance = @import("../io_instance.zig");

fn paramCacheIo() std.Io {
    return io_instance.io;
}

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
    /// Parameterized routes fall back to linear scan (cached in
    /// `param_route_cache` via FIFO eviction).
    static_routes: std.StringHashMap(usize),
    /// FIFO cache for parameterized route lookups. Key is
    /// "{method}:{path}" (e.g. "GET:/users/42"); value is the
    /// route index (or `null` = no match). Capped at 1024 entries;
    /// oldest entry is evicted on overflow.
    param_route_cache: std.StringHashMap(?usize),
    param_cache_order: std.ArrayList([]u8),
    param_cache_max: u32 = 1024,
    /// Guards `param_route_cache` + `param_cache_order`. Server dispatches
    /// concurrent requests on a shared Router; without this lock, FIFO
    /// eviction (enabled after the v0.20.5 double-free fix) races HashMap
    /// mutators and corrupts the heap — often surfacing inside interceptor
    /// execution on the next request.
    param_cache_mutex: std.Io.Mutex = .init,
    global_interceptors: InterceptorChain,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Router {
        return Router{
            .routes = std.ArrayList(Route).empty,
            .static_routes = std.StringHashMap(usize).init(allocator),
            .param_route_cache = std.StringHashMap(?usize).init(allocator),
            .param_cache_order = std.ArrayList([]u8).empty,
            .global_interceptors = InterceptorChain.init(allocator),
            .allocator = allocator,
        };
    }

    const ParamCacheLookup = union(enum) {
        miss,
        negative,
        hit: usize,
    };

    fn paramCacheLookup(self: *Router, key: []const u8) ParamCacheLookup {
        self.param_cache_mutex.lockUncancelable(paramCacheIo());
        defer self.param_cache_mutex.unlock(paramCacheIo());
        if (self.param_route_cache.get(key)) |cached| {
            return if (cached) |idx| .{ .hit = idx } else .negative;
        }
        return .miss;
    }

    /// Insert into FIFO cache; evict oldest if over capacity.
    /// Note: this is FIFO, not LRU — cache hits do NOT re-order. The
    /// oldest entry is always at the front of `param_cache_order`.
    /// Caller must NOT hold `param_cache_mutex`.
    fn paramCachePut(self: *Router, key: []const u8, value: ?usize) !void {
        self.param_cache_mutex.lockUncancelable(paramCacheIo());
        defer self.param_cache_mutex.unlock(paramCacheIo());
        try self.paramCachePutLocked(key, value);
    }

    fn paramCachePutLocked(self: *Router, key: []const u8, value: ?usize) !void {
        // Cap the cache at param_cache_max entries. When full, drop the
        // oldest (FIFO). This is intentionally simple — a true LRU with
        // doubly-linked list would be ~3x more code for marginal gain
        // on workloads with hot route tails.
        //
        // Ownership: hashmap key and order-list entry share ONE allocation
        // (same pointer). Evict by removing the map entry then free once —
        // never free(kv.key) and free(oldest); that double-frees and aborts
        // under Zig's GPA / ASAN once the cache fills (param_cache_max).
        while (self.param_cache_order.items.len >= self.param_cache_max) {
            const oldest = self.param_cache_order.orderedRemove(0);
            _ = self.param_route_cache.fetchRemove(oldest);
            self.allocator.free(oldest);
        }
        const key_dup = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_dup);
        const gop = try self.param_route_cache.getOrPut(key_dup);
        if (gop.found_existing) {
            // Map already owns a key with this content — drop the duplicate
            // and refresh the value. Do not append to the order list again.
            self.allocator.free(key_dup);
            gop.value_ptr.* = value;
            return;
        }
        gop.value_ptr.* = value;
        // If append fails, drop the map entry so errdefer can free key_dup
        // without leaving a dangling hashmap pointer.
        errdefer _ = self.param_route_cache.fetchRemove(key_dup);
        try self.param_cache_order.append(self.allocator, key_dup);
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
        // The hashmap keys and the order-list items share the same
        // allocation (we dupe once in paramCachePut and store the
        // pointer in both). Free them only via the order list.
        for (self.param_cache_order.items) |item| self.allocator.free(item);
        self.param_cache_order.deinit(self.allocator);
        self.param_route_cache.deinit();
        self.global_interceptors.deinit();
        self.* = undefined;
    }

    /// 添加路由（任意 HTTP 方法）
    pub fn add(self: *Router, path: []const u8, handler: Handler) !void {
        try self.addWithMethod(path, .ANY, handler);
    }

    /// 添加指定 HTTP 方法的路由
    pub fn addWithMethod(self: *Router, path: []const u8, method: HttpMethod, handler: Handler) !void {
        try self.addWithMethodAndInterceptors(path, method, handler, InterceptorChain.init(self.allocator));
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
        // First registration wins (same as linear-scan first-match).
        if (parsed.param_names.len == 0) {
            var key_buf: [256]u8 = undefined;
            const key = staticRouteKey(method, owned_path, &key_buf);
            const key_owned = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(key_owned);
            const gop = try self.static_routes.getOrPut(key_owned);
            if (gop.found_existing) {
                self.allocator.free(key_owned);
            } else {
                gop.value_ptr.* = self.routes.items.len - 1;
            }
        }
    }

    /// Build the hashmap lookup key for a method + path combination.
    /// Writes into buf, returns the populated slice. If too long for the buffer,
    /// returns only the path portion (hashmap lookup will miss, falling back to linear scan).
    fn staticRouteKey(method: HttpMethod, path: []const u8, buf: *[256]u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}:{s}", .{ @tagName(method), path }) catch path;
    }

    /// 查找匹配的路由
    pub fn match(self: *Router, path: []const u8, method: HttpMethod) ?*Route {
        return if (self.matchIndex(path, method)) |idx| &self.routes.items[idx] else null;
    }

    /// Like `match`, but returns a stable route index (safe across concurrent
    /// param-cache updates; prefer this inside `execute`).
    pub fn matchIndex(self: *Router, path: []const u8, method: HttpMethod) ?usize {
        // O(1) fast path for exact-match static routes
        var key_buf: [256]u8 = undefined;
        const method_key = staticRouteKey(method, path, &key_buf);
        if (self.static_routes.get(method_key)) |idx| {
            return idx;
        }
        // Also try ANY-method static routes
        const any_key = staticRouteKey(.ANY, path, &key_buf);
        if (self.static_routes.get(any_key)) |idx| {
            return idx;
        }

        // Parameterized-route cache (FIFO, capped). Key includes method
        // so GET /users/42 and POST /users/42 don't collide.
        const cache_key = staticRouteKey(method, path, &key_buf);
        switch (self.paramCacheLookup(cache_key)) {
            .hit => |idx| return idx,
            .negative => return null,
            .miss => {},
        }

        // Fall back to O(n) linear scan for parameterized routes
        var found: ?usize = null;
        for (self.routes.items, 0..) |*route, idx| {
            if (route.matches(path, method)) {
                found = idx;
                break;
            }
        }
        // Cache the result (or negative result) to skip the scan on
        // repeat hits to the same parameterized URL.
        self.paramCachePut(cache_key, found) catch {};
        return found;
    }

    /// 执行路由处理
    pub fn execute(self: *Router, path: []const u8, method: HttpMethod, ctx: *Context) !void {
        const idx = self.matchIndex(path, method) orelse {
            // Route not matched — still run global interceptors (e.g. CORS preflight)
            for (self.global_interceptors.interceptors.items) |interceptor| {
                if (interceptor.before) |before| {
                    if (!(try before(ctx))) return;
                }
            }
            ctx.res_status = .not_found;
            try ctx.renderText("404 Not Found");
            return;
        };

        // Snapshot handler by index; re-read route fields after allocations so
        // we never keep a dangling `*Route` across param-cache / chain setup.
        const handler = self.routes.items[idx].handler;

        if (self.routes.items[idx].param_names.len > 0) {
            ctx.path_params = try self.routes.items[idx].extractParams(path, self.allocator);
        }

        const has_interceptors = self.global_interceptors.interceptors.items.len > 0 or
            self.routes.items[idx].interceptors.interceptors.items.len > 0;

        if (has_interceptors) {
            var combined = InterceptorChain.init(self.allocator);
            defer combined.deinit();

            const total_count = self.global_interceptors.interceptors.items.len +
                self.routes.items[idx].interceptors.interceptors.items.len;
            try combined.interceptors.ensureTotalCapacity(self.allocator, total_count);

            for (self.global_interceptors.interceptors.items) |interceptor| {
                combined.interceptors.appendAssumeCapacity(interceptor);
            }
            for (self.routes.items[idx].interceptors.interceptors.items) |interceptor| {
                combined.interceptors.appendAssumeCapacity(interceptor);
            }

            try combined.execute(ctx, handler);
        } else {
            try handler(ctx);
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
    const h = struct {
        fn f(_: *Context) !void {}
    }.f;
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

    const h = struct {
        fn f(_: *Context) !void {}
    }.f;
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

    const h = struct {
        fn f(_: *Context) !void {}
    }.f;
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

    const h = struct {
        fn f(_: *Context) !void {}
    }.f;
    try router.add("/api/any", h); // .ANY method

    try std.testing.expect(router.match("/api/any", .GET) != null);
    try std.testing.expect(router.match("/api/any", .POST) != null);
    try std.testing.expect(router.match("/api/any", .DELETE) != null);
}

test "route registration order priority" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const h1 = struct {
        fn f(_: *Context) !void {}
    }.f;
    const h2 = struct {
        fn f(_: *Context) !void {}
    }.f;
    try router.addWithMethod("/api/data", .GET, h1);
    try router.addWithMethod("/api/data", .GET, h2); // duplicate, both stored

    // First registered route matches (linear scan)
    const route = router.match("/api/data", .GET).?;
    // Both registered — priority is first-match
    try std.testing.expect(route.handler == h1);
}

test "param route cache FIFO eviction no double-free" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();
    // Tiny cap so eviction runs quickly under GPA.
    router.param_cache_max = 4;

    const h = struct {
        fn f(_: *Context) !void {}
    }.f;
    try router.addWithMethod("/users/:id", .GET, h);

    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const path = try std.fmt.bufPrint(&buf, "/users/{d}", .{i});
        try std.testing.expect(router.match(path, .GET) != null);
    }
    try std.testing.expect(router.param_cache_order.items.len <= router.param_cache_max);
    // Hot path after eviction still resolves (may miss cache → rescan → reinsert).
    try std.testing.expect(router.match("/users/0", .GET) != null);
    try std.testing.expect(router.match("/users/63", .GET) != null);
}

test "param cache + route interceptors survive eviction" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();
    router.param_cache_max = 4;

    const before_fn = struct {
        fn f(_: *Context) !bool {
            return true;
        }
    }.f;

    var chain = InterceptorChain.init(allocator);
    try chain.add(.{ .name = "count", .before = before_fn });

    const h = struct {
        fn f(_: *Context) !void {}
    }.f;
    try router.addWithMethodAndInterceptors("/items/:id", .GET, h, chain);

    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const path = try std.fmt.bufPrint(&buf, "/items/{d}", .{i});
        const route = router.match(path, .GET).?;
        try std.testing.expect(route.interceptors.interceptors.items.len == 1);
        try std.testing.expectEqualStrings("count", route.interceptors.interceptors.items[0].name);
        try std.testing.expect(route.interceptors.interceptors.items[0].before != null);
    }
    const again = router.match("/items/0", .GET).?;
    try std.testing.expect(again.interceptors.interceptors.items.len == 1);
    try std.testing.expectEqualStrings("count", again.interceptors.interceptors.items[0].name);
}
