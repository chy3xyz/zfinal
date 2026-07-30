//! One-shot HTTP client helper for tests and local scripts (Axum `oneshot` analogue).
//! Spins `ZFinal` on a fixed port in a background thread, issues one request, then shuts down.
const std = @import("std");
const ZFinal = @import("zfinal.zig").ZFinal;
const Router = @import("router.zig").Router;
const HttpMethod = @import("router.zig").HttpMethod;
const Context = @import("context.zig").Context;
const state = @import("state.zig");
const shutdown = @import("shutdown.zig");
const io_instance = @import("../io_instance.zig");

fn sleepMs(ms: u64) void {
    const io = if (@import("builtin").is_test) std.testing.io else io_instance.io;
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .real) catch {};
}

pub const Result = struct {
    status: u16,
    body: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

/// In-process Router.execute with `Context.capture` (no TCP).
/// Handlers must use `renderJson`/`renderText`/`renderHtml`.
/// Optional `headers`/`body` populate `mock_headers`/`mock_body` so extractors
/// and JWT/CSRF interceptors can be tested without TCP.
pub fn capture(
    allocator: std.mem.Allocator,
    router: *Router,
    method: HttpMethod,
    path: []const u8,
    app_state: state.Handle,
) !Result {
    return captureWith(allocator, router, method, path, app_state, &.{}, null);
}

pub const HeaderPair = struct { name: []const u8, value: []const u8 };

pub fn captureWith(
    allocator: std.mem.Allocator,
    router: *Router,
    method: HttpMethod,
    path: []const u8,
    app_state: state.Handle,
    headers: []const HeaderPair,
    body: ?[]const u8,
) !Result {
    var cap: Context.CapturedResponse = .{ .allocator = allocator };
    errdefer cap.deinit();

    var ctx: Context = .{
        .req = undefined,
        .allocator = allocator,
        .attributes = .init(allocator),
        .response_cookies = .empty,
        .response_headers = .init(allocator),
        .app_state = app_state,
        .capture = &cap,
        .compress_enabled = false,
        .mock_body = body,
    };
    defer ctx.deinit();

    if (headers.len > 0) {
        ctx.mock_headers = .init(allocator);
        for (headers) |h| {
            try ctx.mock_headers.?.put(h.name, h.value);
        }
    }

    try router.execute(path, method, &ctx);

    return .{
        .status = @intFromEnum(cap.status),
        .body = try cap.body.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

test "capture executes handler without TCP" {
    const testing = std.testing;
    var router = Router.init(testing.allocator);
    defer router.deinit();
    try router.addWithMethod("/ping", .GET, struct {
        fn h(ctx: *Context) !void {
            try ctx.renderJson(.{ .ok = true });
        }
    }.h);
    try router.seal();
    var res = try capture(testing.allocator, &router, .GET, "/ping", .{});
    defer res.deinit();
    try testing.expectEqual(@as(u16, 200), res.status);
    try testing.expect(std.mem.indexOf(u8, res.body, "true") != null);
}

test "captureWith exposes mock Authorization header" {
    const testing = std.testing;
    var router = Router.init(testing.allocator);
    defer router.deinit();
    try router.addWithMethod("/who", .GET, struct {
        fn h(ctx: *Context) !void {
            const auth = ctx.getHeader("Authorization") orelse {
                try ctx.renderJson(.{ .ok = false });
                return;
            };
            try ctx.renderJson(.{ .auth = auth });
        }
    }.h);
    try router.seal();
    var res = try captureWith(
        testing.allocator,
        &router,
        .GET,
        "/who",
        .{},
        &.{.{ .name = "Authorization", .value = "Bearer tok" }},
        null,
    );
    defer res.deinit();
    try testing.expect(std.mem.indexOf(u8, res.body, "Bearer tok") != null);
}

/// Allow oneshot to re-run after a previous shutdown.
pub fn resetShutdown() void {
    shutdown.shutting_down.store(false, .monotonic);
}

pub fn requestShutdown() void {
    shutdown.shutting_down.store(true, .monotonic);
}

/// HTTP fetch against `http://127.0.0.1:{port}{path}`.
pub fn fetch(
    allocator: std.mem.Allocator,
    io: std.Io,
    port: u16,
    method: std.http.Method,
    path: []const u8,
    body: ?[]const u8,
) !Result {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ port, path });
    defer allocator.free(url);

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = body,
        .response_writer = &response_body.writer,
    });

    return .{
        .status = @intFromEnum(result.status),
        .body = try response_body.toOwnedSlice(),
        .allocator = allocator,
    };
}

const ServerThread = struct {
    port: u16,
    register: *const fn (*ZFinal) anyerror!void,
    ready: *std.atomic.Value(bool),
    failed: *std.atomic.Value(bool),

    fn run(self: *ServerThread) void {
        var app = ZFinal.init(std.heap.page_allocator);
        defer app.deinit();
        app.setConfig(.{
            .host = "127.0.0.1",
            .port = self.port,
            .drain_timeout_ms = 1_000,
            .request_timeout_ms = 5_000,
            .read_timeout_ms = 5_000,
            .write_timeout_ms = 5_000,
            .force_connection_close = true,
        });
        self.register(&app) catch {
            self.failed.store(true, .release);
            self.ready.store(true, .release);
            return;
        };
        self.ready.store(true, .release);
        app.start() catch {};
    }
};

/// Register routes via `register`, serve on `port`, perform one request, then shut down.
pub fn against(
    allocator: std.mem.Allocator,
    port: u16,
    register: *const fn (*ZFinal) anyerror!void,
    method: std.http.Method,
    path: []const u8,
    body: ?[]const u8,
) !Result {
    resetShutdown();
    defer requestShutdown();

    var ready = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);
    var thr_ctx: ServerThread = .{
        .port = port,
        .register = register,
        .ready = &ready,
        .failed = &failed,
    };
    const thread = try std.Thread.spawn(.{}, ServerThread.run, .{&thr_ctx});
    defer thread.join();

    var waits: u32 = 0;
    while (!ready.load(.acquire)) : (waits += 1) {
        if (waits > 200) return error.ServerNotReady;
        sleepMs(10);
    }
    if (failed.load(.acquire)) return error.ServerSetupFailed;

    // Brief settle for listen()
    sleepMs(50);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    var last_err: anyerror = error.FetchFailed;
    var attempt: u32 = 0;
    while (attempt < 30) : (attempt += 1) {
        const res = fetch(allocator, threaded.io(), port, method, path, body) catch |err| {
            last_err = err;
            sleepMs(20);
            continue;
        };
        return res;
    }
    return last_err;
}

test "oneshot Result owns body" {
    const testing = std.testing;
    var res: Result = .{
        .status = 200,
        .body = try testing.allocator.dupe(u8, "{\"ok\":true}"),
        .allocator = testing.allocator,
    };
    defer res.deinit();
    try testing.expectEqual(@as(u16, 200), res.status);
}

// Full `against` spins a real server thread — use manually / in CI soak; not default unit test.
