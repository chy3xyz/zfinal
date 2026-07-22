const std = @import("std");
const Context = @import("../core/context.zig").Context;
const jwt = @import("../auth/jwt.zig");
const audit = @import("../core/audit.zig");

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
/// Do **not** use for production — use `createJwtAuthInterceptor`.
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

/// Production JWT (HS256) auth. Expects `Authorization: Bearer <token>`.
pub fn createJwtAuthInterceptor(secret: []const u8) Interceptor {
    return createJwtAuthInterceptorWithOptions(secret, .{});
}

/// Production JWT with `VerifyOptions` (iss/aud/rotation/leeway).
pub fn createJwtAuthInterceptorWithOptions(secret: []const u8, opts: jwt.VerifyOptions) Interceptor {
    const Impl = struct {
        var sec: []const u8 = undefined;
        var verify_opts: jwt.VerifyOptions = undefined;

        fn before(ctx: *Context) !bool {
            const hdr = ctx.getHeader("Authorization") orelse {
                ctx.res_status = .unauthorized;
                try ctx.renderJson(.{ .err = "Missing Authorization" });
                return false;
            };
            const prefix = "Bearer ";
            if (hdr.len <= prefix.len or !std.ascii.eqlIgnoreCase(hdr[0..prefix.len], prefix)) {
                ctx.res_status = .unauthorized;
                try ctx.renderJson(.{ .err = "Expected Bearer token" });
                return false;
            }
            const token = hdr[prefix.len..];
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            const now: i64 = @intCast(ts.sec);

            const claims = jwt.verifyWithOptions(ctx.allocator, sec, token, now, verify_opts) catch {
                const path = if (std.mem.indexOfScalar(u8, ctx.req.head.target, '?')) |q|
                    ctx.req.head.target[0..q]
                else
                    ctx.req.head.target;
                audit.log(.auth_fail, path, "jwt");
                ctx.res_status = .unauthorized;
                try ctx.renderJson(.{ .err = "Invalid or expired token" });
                return false;
            };
            defer jwt.freeClaims(ctx.allocator, claims);
            try ctx.setAttr("jwt_sub", claims.sub);
            if (claims.role) |role| {
                try ctx.setAttr("jwt_role", role);
            }
            return true;
        }
    };
    Impl.sec = secret;
    Impl.verify_opts = opts;
    return Interceptor{
        .name = "jwt_auth",
        .before = Impl.before,
    };
}

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
    return createCorsAllowlistInterceptor(&.{allowed_origin});
}

/// Production CORS with an allow-list of origins. Reflects request Origin when matched.
pub fn createCorsAllowlistInterceptor(allowed_origins: []const []const u8) Interceptor {
    const Impl = struct {
        var origins: []const []const u8 = &.{};

        fn before(ctx: *Context) !bool {
            const req_origin = ctx.getHeader("Origin");
            var matched: ?[]const u8 = null;
            if (req_origin) |o| {
                for (origins) |allowed| {
                    if (std.mem.eql(u8, allowed, o)) {
                        matched = allowed;
                        break;
                    }
                }
            } else if (origins.len == 1) {
                // Non-browser / same-origin tools: still emit the configured origin.
                matched = origins[0];
            }

            if (matched) |m| {
                try ctx.setHeader("Access-Control-Allow-Origin", m);
                try ctx.setHeader("Vary", "Origin");
                try ctx.setHeader("Access-Control-Allow-Credentials", "true");
            }
            try ctx.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS, PATCH");
            try ctx.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Requested-With");

            if (ctx.req.head.method == .OPTIONS) {
                ctx.res_status = .ok;
                try ctx.renderText("");
                return false;
            }
            return true;
        }
    };
    Impl.origins = allowed_origins;
    return Interceptor{
        .name = "cors_allowlist",
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
