const std = @import("std");
const Context = @import("../core/context.zig").Context;

pub const Handler = *const fn (*Context) anyerror!void;

/// Interceptor for AOP-style request handling
pub const Interceptor = struct {
    name: []const u8,
    before: ?*const fn (*Context) anyerror!bool = null,
    after: ?*const fn (*Context) anyerror!void = null,

    /// Execute interceptor chain with handler
    pub fn intercept(self: *const Interceptor, ctx: *Context, handler: Handler) !void {
        // Execute before interceptor
        if (self.before) |beforeFn| {
            const should_continue = try beforeFn(ctx);
            if (!should_continue) {
                // Before interceptor returned false, skip handler
                return;
            }
        }

        // Execute handler
        try handler(ctx);

        // Execute after interceptor
        if (self.after) |afterFn| {
            try afterFn(ctx);
        }
    }
};

/// Interceptor chain for multiple interceptors
pub const InterceptorChain = struct {
    interceptors: std.ArrayList(Interceptor),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) InterceptorChain {
        return InterceptorChain{
            .interceptors = std.ArrayList(Interceptor).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *InterceptorChain) void {
        self.interceptors.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *InterceptorChain, interceptor: Interceptor) !void {
        try self.interceptors.append(self.allocator, interceptor);
    }

    /// Execute all interceptors in chain with handler
    pub fn execute(self: *const InterceptorChain, ctx: *Context, handler: Handler) !void {
        if (self.interceptors.items.len == 0) {
            // No interceptors, just execute handler
            try handler(ctx);
            return;
        }

        // Execute before interceptors
        for (self.interceptors.items) |*interceptor| {
            if (interceptor.before) |beforeFn| {
                const should_continue = try beforeFn(ctx);
                if (!should_continue) {
                    // Interceptor stopped execution
                    return;
                }
            }
        }

        // Execute handler
        try handler(ctx);

        // Execute after interceptors (in reverse order)
        var i: usize = self.interceptors.items.len;
        while (i > 0) {
            i -= 1;
            const interceptor = &self.interceptors.items[i];
            if (interceptor.after) |afterFn| {
                try afterFn(ctx);
            }
        }
    }
};

// Common interceptors

test "interceptor chain structure" {
    const a = std.testing.allocator;
    var chain = InterceptorChain.init(a);
    defer chain.deinit();
    const before_fn = struct {
        fn f(_: *Context) !bool {
            return true;
        }
    }.f;
    const after_fn = struct {
        fn f(_: *Context) !void {}
    }.f;
    const int1 = Interceptor{ .name = "first", .before = before_fn };
    const int2 = Interceptor{ .name = "second", .after = after_fn };
    try chain.add(int1);
    try chain.add(int2);
    try std.testing.expectEqual(@as(usize, 2), chain.interceptors.items.len);
    try std.testing.expectEqualStrings("first", chain.interceptors.items[0].name);
    try std.testing.expectEqualStrings("second", chain.interceptors.items[1].name);
}

/// Logging interceptor
pub fn loggingBefore(ctx: *Context) !bool {
    const target = ctx.req.head.target;
    const method = @tagName(ctx.req.head.method);
    std.debug.print("[{s}] {s}\n", .{ method, target });
    return true;
}

pub fn loggingAfter(ctx: *Context) !void {
    const status = @intFromEnum(ctx.res_status);
    std.debug.print("Response: {d}\n", .{status});
}

pub const LoggingInterceptor = Interceptor{
    .name = "logging",
    .before = loggingBefore,
    .after = loggingAfter,
};

/// Demo-only auth: checks cookie `auth_token` **presence**, not validity.
/// Do **not** use for production — implement JWT/session verification yourself.
pub fn authBefore(ctx: *Context) !bool {
    const token = try ctx.getCookie("auth_token");
    if (token == null) {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .err = "Unauthorized" });
        return false;
    }
    return true;
}

pub const AuthInterceptor = Interceptor{
    .name = "auth",
    .before = authBefore,
};

/// Default CORS: `Access-Control-Allow-Origin: *`.
/// **Not safe for credentialed browser APIs.** Prefer `createCorsInterceptor`.
pub fn corsBefore(ctx: *Context) !bool {
    try ctx.setHeader("Access-Control-Allow-Origin", "*");
    try ctx.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS, PATCH");
    try ctx.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Requested-With");

    if (ctx.req.head.method == .OPTIONS) {
        ctx.res_status = .ok;
        try ctx.renderText("");
        return false;
    }

    return true;
}

pub fn corsAfter(ctx: *Context) !void {
    _ = ctx;
}

pub const CORSInterceptor = Interceptor{
    .name = "cors",
    .before = corsBefore,
    .after = corsAfter,
};

/// Production-oriented CORS: single explicit origin (no wildcard).
pub fn createCorsInterceptor(allowed_origin: []const u8) Interceptor {
    const Impl = struct {
        var origin: []const u8 = undefined;

        fn before(ctx: *Context) !bool {
            try ctx.setHeader("Access-Control-Allow-Origin", origin);
            try ctx.setHeader("Vary", "Origin");
            try ctx.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS, PATCH");
            try ctx.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Requested-With");
            try ctx.setHeader("Access-Control-Allow-Credentials", "true");

            if (ctx.req.head.method == .OPTIONS) {
                ctx.res_status = .ok;
                try ctx.renderText("");
                return false;
            }
            return true;
        }
    };
    Impl.origin = allowed_origin;
    return Interceptor{
        .name = "cors_restricted",
        .before = Impl.before,
        .after = corsAfter,
    };
}

test "interceptor basic" {
    const allocator = std.testing.allocator;

    const testHandler = struct {
        fn handler(ctx: *Context) !void {
            _ = ctx;
            // Handler would be called here
        }
    }.handler;

    // Create a simple interceptor
    const interceptor = Interceptor{
        .name = "test",
        .before = struct {
            fn before(ctx: *Context) !bool {
                _ = ctx;
                return true;
            }
        }.before,
    };

    // Note: Full test would require creating a mock Context
    _ = interceptor;
    _ = testHandler;
    _ = allocator;
}
