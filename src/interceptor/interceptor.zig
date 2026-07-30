const std = @import("std");
const Context = @import("../core/context.zig").Context;
const jwt = @import("../auth/jwt.zig");
const audit = @import("../core/audit.zig");
const http_error = @import("../core/http_error.zig");

pub const Handler = *const fn (*Context) anyerror!void;

/// Process-lifetime heap config for interceptor factories (JWT/CORS/stock, …).
/// Prefer caller-owned pointers when available (e.g. `*RateLimitHandler`).
pub fn heapCfg(comptime T: type, value: T) *T {
    const p = std.heap.page_allocator.create(T) catch @panic("interceptor config OOM");
    p.* = value;
    return p;
}

fn runBefore(interceptor: *const Interceptor, ctx: *Context) !bool {
    if (interceptor.before_ud) |f| return try f(ctx, interceptor.userdata);
    if (interceptor.before) |f| return try f(ctx);
    return true;
}

fn runAfter(interceptor: *const Interceptor, ctx: *Context) !void {
    if (interceptor.after_ud) |f| {
        try f(ctx, interceptor.userdata);
        return;
    }
    if (interceptor.after) |f| try f(ctx);
}

/// Interceptor for AOP-style request handling.
/// Prefer `before_ud`/`userdata` for per-instance config (no static `var`).
pub const Interceptor = struct {
    name: []const u8,
    before: ?*const fn (*Context) anyerror!bool = null,
    after: ?*const fn (*Context) anyerror!void = null,
    /// Opaque per-instance config; used when `before_ud` / `after_ud` are set.
    userdata: ?*anyopaque = null,
    before_ud: ?*const fn (*Context, ?*anyopaque) anyerror!bool = null,
    after_ud: ?*const fn (*Context, ?*anyopaque) anyerror!void = null,

    /// Execute interceptor chain with handler
    pub fn intercept(self: *const Interceptor, ctx: *Context, handler: Handler) !void {
        if (!(try runBefore(self, ctx))) return;
        try handler(ctx);
        try runAfter(self, ctx);
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

        for (self.interceptors.items) |*interceptor| {
            if (!(try runBefore(interceptor, ctx))) return;
        }

        try handler(ctx);

        var i: usize = self.interceptors.items.len;
        while (i > 0) {
            i -= 1;
            try runAfter(&self.interceptors.items[i], ctx);
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
        http_error.setDetail(ctx, "auth_token");
        return error.Unauthorized;
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

const JwtAuthCfg = struct {
    sec: []const u8,
    verify_opts: jwt.VerifyOptions,
};

/// Production JWT with `VerifyOptions` (iss/aud/rotation/leeway).
/// Config is heap-copied once (process lifetime) so multiple instances do not share static vars.
pub fn createJwtAuthInterceptorWithOptions(secret: []const u8, opts: jwt.VerifyOptions) Interceptor {
    const cfg = heapCfg(JwtAuthCfg, .{ .sec = secret, .verify_opts = opts });
    return Interceptor{
        .name = "jwt_auth",
        .userdata = cfg,
        .before_ud = struct {
            fn before(ctx: *Context, ud: ?*anyopaque) !bool {
                const c: *JwtAuthCfg = @ptrCast(@alignCast(ud.?));
                const hdr = ctx.getHeader("Authorization") orelse {
                    http_error.setDetail(ctx, "Authorization");
                    return error.Unauthorized;
                };
                const prefix = "Bearer ";
                if (hdr.len <= prefix.len or !std.ascii.eqlIgnoreCase(hdr[0..prefix.len], prefix)) {
                    http_error.setDetail(ctx, "Authorization");
                    return error.Unauthorized;
                }
                const token = hdr[prefix.len..];
                var ts: std.c.timespec = undefined;
                _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
                const now: i64 = @intCast(ts.sec);

                const claims = jwt.verifyWithOptions(ctx.allocator, c.sec, token, now, c.verify_opts) catch {
                    const path = if (std.mem.indexOfScalar(u8, ctx.req.head.target, '?')) |q|
                        ctx.req.head.target[0..q]
                    else
                        ctx.req.head.target;
                    audit.log(.auth_fail, path, "jwt");
                    http_error.setDetail(ctx, "jwt");
                    return error.Unauthorized;
                };
                defer jwt.freeClaims(ctx.allocator, claims);
                try ctx.setAttr("jwt_sub", claims.sub);
                if (claims.role) |role| {
                    try ctx.setAttr("jwt_role", role);
                }
                try ctx.setExt(@import("../core/extension.zig").JwtIdentity, .{
                    .sub = ctx.getAttr("jwt_sub").?,
                    .role = ctx.getAttr("jwt_role") orelse "",
                });
                return true;
            }
        }.before,
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

const CorsCfg = struct { origins: []const []const u8 };

/// Production CORS with an allow-list of origins. Reflects request Origin when matched.
/// `allowed_origins` must outlive the interceptor (typically static / AppState).
pub fn createCorsAllowlistInterceptor(allowed_origins: []const []const u8) Interceptor {
    const cfg = heapCfg(CorsCfg, .{ .origins = allowed_origins });
    return Interceptor{
        .name = "cors_allowlist",
        .userdata = cfg,
        .before_ud = struct {
            fn before(ctx: *Context, ud: ?*anyopaque) !bool {
                const origins = @as(*CorsCfg, @ptrCast(@alignCast(ud.?))).origins;
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
        }.before,
        .after = corsAfter,
    };
}

test "jwt auth interceptor uses distinct userdata configs" {
    const a = createJwtAuthInterceptorWithOptions("secret-a-min-32-bytes!!!!!!!!!!!!!!", .{});
    const b = createJwtAuthInterceptorWithOptions("secret-b-min-32-bytes!!!!!!!!!!!!!!", .{});
    try std.testing.expect(a.userdata != b.userdata);
    const ca: *JwtAuthCfg = @ptrCast(@alignCast(a.userdata.?));
    const cb: *JwtAuthCfg = @ptrCast(@alignCast(b.userdata.?));
    try std.testing.expectEqualStrings("secret-a-min-32-bytes!!!!!!!!!!!!!!", ca.sec);
    try std.testing.expectEqualStrings("secret-b-min-32-bytes!!!!!!!!!!!!!!", cb.sec);
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
