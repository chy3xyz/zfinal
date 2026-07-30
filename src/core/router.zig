const std = @import("std");
const Context = @import("context.zig").Context;
const http_error = @import("http_error.zig");
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

/// 路由段类型（smart_routing：static > :param > *wildcard）
const SegmentType = enum {
    static,
    param,
    wildcard,
};

/// 路由段
const Segment = struct {
    type: SegmentType,
    value: []const u8,
};

/// 路由定义
pub const Route = struct {
    pattern: []const u8, // 路径模式，如 "/users/:id" 或 "/assets/*path"
    method: HttpMethod, // HTTP 方法
    handler: Handler,
    interceptors: InterceptorChain,
    segments: []Segment, // 预解析的路由段
    param_names: [][]const u8, // 参数名列表（含通配名）
    has_wildcard: bool = false,

    /// 方法 + 路径均匹配
    pub fn matches(self: *const Route, path: []const u8, method: HttpMethod) bool {
        if (self.method != .ANY and self.method != method) return false;
        return self.matchesPath(path);
    }

    /// 仅路径形状匹配（用于 405 Allow 收集）
    pub fn matchesPath(self: *const Route, path: []const u8) bool {
        if (self.param_names.len == 0) {
            return std.mem.eql(u8, self.pattern, path);
        }

        var path_it = std.mem.splitScalar(u8, path, '/');
        if (path.len > 0 and path[0] == '/') {
            _ = path_it.next();
        }

        for (self.segments) |segment| {
            switch (segment.type) {
                .static => {
                    const path_part = path_it.next() orelse return false;
                    if (!std.mem.eql(u8, segment.value, path_part)) return false;
                },
                .param => {
                    const path_part = path_it.next() orelse return false;
                    if (path_part.len == 0) return false;
                },
                .wildcard => {
                    // 至少一段非空后缀；吃掉剩余全部
                    const first = path_it.next() orelse return false;
                    if (first.len == 0) return false;
                    while (path_it.next()) |_| {}
                    return true;
                },
            }
        }

        return path_it.next() == null;
    }

    /// 匹配特异度：静态 > 参数 > 通配（同前缀下更具体者优先）
    pub fn specificity(self: *const Route) i32 {
        var score: i32 = 0;
        for (self.segments) |segment| {
            score += switch (segment.type) {
                .static => @as(i32, 1000),
                .param => 10,
                .wildcard => 1,
            };
        }
        if (self.has_wildcard) score -= 100_000;
        return score;
    }

    /// 提取路径参数（通配值为 path 上的连续子串，无分配）
    pub fn extractParams(self: *const Route, path: []const u8, allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
        var params = std.StringHashMap([]const u8).init(allocator);
        errdefer params.deinit();
        if (self.param_names.len == 0) return params;

        var path_it = std.mem.splitScalar(u8, path, '/');
        if (path.len > 0 and path[0] == '/') {
            _ = path_it.next();
        }

        for (self.segments) |segment| {
            switch (segment.type) {
                .static => {
                    _ = path_it.next() orelse break;
                },
                .param => {
                    const path_part = path_it.next() orelse break;
                    try params.put(segment.value, path_part);
                },
                .wildcard => {
                    const first = path_it.next() orelse break;
                    const offset = @intFromPtr(first.ptr) - @intFromPtr(path.ptr);
                    var rest = path[offset..];
                    if (rest.len > 0 and rest[rest.len - 1] == '/') {
                        rest = rest[0 .. rest.len - 1];
                    }
                    try params.put(segment.value, rest);
                    while (path_it.next()) |_| {}
                },
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
    /// After `seal()`, further `add*` calls fail with `error.RouterSealed`.
    sealed: bool = false,
    /// Optional SPA / custom 404 handler when no route matches (and not 405).
    fallback: ?Handler = null,

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

    pub fn setFallback(self: *Router, handler: Handler) !void {
        if (self.sealed) return error.RouterSealed;
        self.fallback = handler;
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
        if (self.sealed) return error.RouterSealed;

        const parsed = try parseRoute(path, self.allocator);
        errdefer {
            self.allocator.free(parsed.segments);
            self.allocator.free(parsed.param_names);
        }

        // 同 METHOD + pattern → 失败（smart_routing：禁止静默覆盖）
        for (self.routes.items) |*existing| {
            if (existing.method == method and std.mem.eql(u8, existing.pattern, path)) {
                return error.DuplicateRoute; // errdefer frees parsed.*
            }
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
            .has_wildcard = parsed.has_wildcard,
        };

        try self.routes.append(self.allocator, route);

        // O(1) fast path: index static routes (no params / wildcards)
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

    /// Freeze the route table: sort by specificity (desc), rebuild static index,
    /// reject further registrations. Call once after all modules `register`.
    pub fn seal(self: *Router) !void {
        if (self.sealed) return;
        // Insertion sort by specificity descending (stable enough for small N)
        var i: usize = 1;
        while (i < self.routes.items.len) : (i += 1) {
            var j = i;
            while (j > 0 and self.routes.items[j].specificity() > self.routes.items[j - 1].specificity()) {
                const tmp = self.routes.items[j];
                self.routes.items[j] = self.routes.items[j - 1];
                self.routes.items[j - 1] = tmp;
                j -= 1;
            }
        }
        // Rebuild static map with new indices
        var key_it = self.static_routes.keyIterator();
        while (key_it.next()) |key| self.allocator.free(key.*);
        self.static_routes.clearRetainingCapacity();
        for (self.routes.items, 0..) |*route, idx| {
            if (route.param_names.len != 0) continue;
            var key_buf: [256]u8 = undefined;
            const key = staticRouteKey(route.method, route.pattern, &key_buf);
            const key_owned = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(key_owned);
            const gop = try self.static_routes.getOrPut(key_owned);
            if (gop.found_existing) {
                self.allocator.free(key_owned);
            } else {
                gop.value_ptr.* = idx;
            }
        }
        // Drop param cache — indices may have moved
        for (self.param_cache_order.items) |item| self.allocator.free(item);
        self.param_cache_order.clearRetainingCapacity();
        self.param_route_cache.clearRetainingCapacity();
        self.sealed = true;
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
    /// HEAD 无专属路由时回退到同 path 的 GET（smart_routing §5.5）。
    pub fn matchIndex(self: *Router, path: []const u8, method: HttpMethod) ?usize {
        if (self.matchIndexForMethod(path, method)) |idx| return idx;
        if (method == .HEAD) return self.matchIndexForMethod(path, .GET);
        return null;
    }

    fn matchIndexForMethod(self: *Router, path: []const u8, method: HttpMethod) ?usize {
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

        // Parameterized / wildcard cache (FIFO). Key includes method.
        const cache_key = staticRouteKey(method, path, &key_buf);
        switch (self.paramCacheLookup(cache_key)) {
            .hit => |idx| return idx,
            .negative => return null,
            .miss => {},
        }

        // 线性扫描：在所有匹配中取特异度最高者（静态 > :param > *wildcard）
        var found: ?usize = null;
        var best_score: i32 = std.math.minInt(i32);
        for (self.routes.items, 0..) |*route, idx| {
            if (route.matches(path, method)) {
                const score = route.specificity();
                if (found == null or score > best_score) {
                    found = idx;
                    best_score = score;
                }
            }
        }
        self.paramCachePut(cache_key, found) catch {};
        return found;
    }

    /// 收集某 path 上已注册的方法（不含 method 过滤），用于 405 Allow。
    fn methodsForPath(self: *Router, path: []const u8, buf: *[8]HttpMethod) []const HttpMethod {
        var n: usize = 0;
        for (self.routes.items) |*route| {
            if (!route.matchesPath(path)) continue;
            if (route.method == .ANY) {
                // ANY → 列出常用方法
                const common = [_]HttpMethod{ .GET, .POST, .PUT, .PATCH, .DELETE, .HEAD, .OPTIONS };
                for (common) |m| {
                    if (n < buf.len and !containsMethod(buf[0..n], m)) {
                        buf[n] = m;
                        n += 1;
                    }
                }
                continue;
            }
            if (n < buf.len and !containsMethod(buf[0..n], route.method)) {
                buf[n] = route.method;
                n += 1;
            }
        }
        return buf[0..n];
    }

    fn containsMethod(hay: []const HttpMethod, needle: HttpMethod) bool {
        for (hay) |m| if (m == needle) return true;
        return false;
    }

    fn formatAllowHeader(methods: []const HttpMethod, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        for (methods, 0..) |m, i| {
            if (i > 0) w.writeAll(", ") catch break;
            w.writeAll(@tagName(m)) catch break;
        }
        return w.buffered();
    }

    /// 执行路由处理
    pub fn execute(self: *Router, path: []const u8, method: HttpMethod, ctx: *Context) !void {
        const idx = self.matchIndex(path, method) orelse {
            for (self.global_interceptors.interceptors.items) |*interceptor| {
                const cont = if (interceptor.before_ud) |f|
                    try f(ctx, interceptor.userdata)
                else if (interceptor.before) |f|
                    try f(ctx)
                else
                    true;
                if (!cont) return;
            }

            var allow_buf: [8]HttpMethod = undefined;
            const allow = self.methodsForPath(path, &allow_buf);
            if (allow.len > 0) {
                var hdr_buf: [128]u8 = undefined;
                const allow_hdr = formatAllowHeader(allow, &hdr_buf);
                try ctx.setHeader("Allow", allow_hdr);
                try http_error.renderStatus(ctx, .method_not_allowed, "method_not_allowed", "Method Not Allowed");
                return;
            }

            if (self.fallback) |fb| {
                try fb(ctx);
                return;
            }

            try http_error.renderStatus(ctx, .not_found, "not_found", "Not Found");
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
    has_wildcard: bool = false,
};

/// 解析路由模式（`:id` / `{id}` 参数；末段 `*path` 尾通配）
fn parseRoute(path: []const u8, allocator: std.mem.Allocator) !ParsedRoute {
    var segments = std.ArrayList(Segment).empty;
    errdefer segments.deinit(allocator);
    var param_names = std.ArrayList([]const u8).empty;
    errdefer param_names.deinit(allocator);

    var parts = std.mem.splitScalar(u8, path, '/');
    if (path.len > 0 and path[0] == '/') {
        _ = parts.next();
    }

    var has_wildcard = false;
    while (parts.next()) |part| {
        if (has_wildcard) return error.InvalidRoutePattern; // * 后禁止再跟段

        if (part.len > 1 and part[0] == '*') {
            const name = part[1..];
            if (name.len == 0) return error.InvalidRoutePattern;
            try segments.append(allocator, .{ .type = .wildcard, .value = name });
            try param_names.append(allocator, name);
            has_wildcard = true;
        } else if (part.len > 0 and part[0] == ':') {
            const name = part[1..];
            if (name.len == 0) return error.InvalidRoutePattern;
            try segments.append(allocator, .{ .type = .param, .value = name });
            try param_names.append(allocator, name);
        } else if (part.len >= 3 and part[0] == '{' and part[part.len - 1] == '}') {
            // 过渡兼容：`{id}` ≡ `:id`（生成器已改为 `:id`）
            const name = part[1 .. part.len - 1];
            if (name.len == 0) return error.InvalidRoutePattern;
            try segments.append(allocator, .{ .type = .param, .value = name });
            try param_names.append(allocator, name);
        } else {
            try segments.append(allocator, .{ .type = .static, .value = part });
        }
    }

    return ParsedRoute{
        .segments = try segments.toOwnedSlice(allocator),
        .param_names = try param_names.toOwnedSlice(allocator),
        .has_wildcard = has_wildcard,
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

test "route registration rejects duplicate METHOD+path" {
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
    try std.testing.expectError(error.DuplicateRoute, router.addWithMethod("/api/data", .GET, h2));

    const route = router.match("/api/data", .GET).?;
    try std.testing.expect(route.handler == h1);
}

test "wildcard route matching and extraction" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();

    const h = struct {
        fn f(_: *Context) !void {}
    }.f;
    try router.addWithMethod("/assets/*path", .GET, h);
    try router.addWithMethod("/assets/logo.png", .GET, h);

    // Exact static wins over wildcard
    const static_hit = router.match("/assets/logo.png", .GET).?;
    try std.testing.expectEqualStrings("/assets/logo.png", static_hit.pattern);

    try std.testing.expect(router.match("/assets", .GET) == null);
    const wild = router.match("/assets/a/b/c.txt", .GET).?;
    try std.testing.expect(wild.has_wildcard);
    var params = try wild.extractParams("/assets/a/b/c.txt", allocator);
    defer params.deinit();
    try std.testing.expectEqualStrings("a/b/c.txt", params.get("path").?);
}

test "HEAD falls back to GET" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();
    const h = struct {
        fn f(_: *Context) !void {}
    }.f;
    try router.addWithMethod("/ping", .GET, h);
    try std.testing.expect(router.match("/ping", .HEAD) != null);
}

test "brace param alias {id}" {
    const allocator = std.testing.allocator;
    const parsed = try parseRoute("/users/{id}", allocator);
    defer allocator.free(parsed.segments);
    defer allocator.free(parsed.param_names);
    try std.testing.expectEqual(@as(usize, 1), parsed.param_names.len);
    try std.testing.expectEqualStrings("id", parsed.param_names[0]);
}

test "router seal rejects further registration" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();
    const h = struct {
        fn f(_: *Context) !void {}
    }.f;
    try router.addWithMethod("/a", .GET, h);
    try router.addWithMethod("/b/:id", .GET, h);
    try router.seal();
    try std.testing.expect(router.sealed);
    try std.testing.expectError(error.RouterSealed, router.addWithMethod("/c", .GET, h));
    // After seal, more-specific still matches
    try std.testing.expect(router.match("/b/1", .GET) != null);
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
