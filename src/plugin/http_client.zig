const std = @import("std");

/// HTTP client wrapping `std.http.Client` (GET/POST/PUT/DELETE).
///
/// Owns a **long-lived dedicated** `Threaded` Io and a reused `std.http.Client`
/// (connection pool survives across requests). Isolates from the server
/// accept/worker Io (hang class) while amortizing Io + TCP/TLS setup.
/// Caller owns `Response.body` and must `deinit` the response.
pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    /// 单次请求的**空闲/读**超时，单位毫秒。0 表示不限制。
    ///
    /// `std.http.Client.fetch` 本身没有 timeout（`FetchOptions` 和 `Client` 都
    /// 没有 deadline 字段），所以这里在 `std.Io` 层用「可取消任务 vs 空闲看门狗」
    /// 竞速实现，见 `fetchWithTimeout`。看门狗在每次收到响应数据时被刷新，因此
    /// 连接卡死/读不到数据才会触发；持续输出的流式响应（如 LLM SSE）不会被误杀。
    timeout_ms: u64 = 10_000,
    /// Isolated from `io_instance` / server Threaded; one per HttpClient.
    threaded: *std.Io.Threaded,
    /// Reused so `connection_pool` keeps idle keep-alive sockets.
    http: *std.http.Client,

    pub const Method = enum { GET, POST, PUT, DELETE };
    pub const Response = struct {
        status: u16,
        body: []const u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Response) void {
            self.allocator.free(self.body);
        }
    };

    /// Callback for streamed response body bytes (as `std.http.Client.fetch` drains).
    pub const OnBodyChunk = *const fn (ctx: *anyopaque, chunk: []const u8) anyerror!void;

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8) !HttpClient {
        const threaded = try allocator.create(std.Io.Threaded);
        errdefer allocator.destroy(threaded);
        threaded.* = std.Io.Threaded.init(allocator, .{});
        errdefer threaded.deinit();

        const http = try allocator.create(std.http.Client);
        errdefer allocator.destroy(http);
        http.* = .{ .allocator = allocator, .io = threaded.io() };

        const base = try allocator.dupe(u8, base_url);
        errdefer allocator.free(base);

        return .{
            .allocator = allocator,
            .base_url = base,
            .threaded = threaded,
            .http = http,
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.http.deinit();
        self.allocator.destroy(self.http);
        self.threaded.deinit();
        self.allocator.destroy(self.threaded);
        self.allocator.free(self.base_url);
    }

    pub fn joinUrl(self: *const HttpClient, path: []const u8) ![]u8 {
        if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) {
            return try self.allocator.dupe(u8, path);
        }
        if (self.base_url.len == 0) return try self.allocator.dupe(u8, path);
        const needs_slash = self.base_url[self.base_url.len - 1] != '/' and (path.len == 0 or path[0] != '/');
        if (needs_slash) {
            return try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.base_url, path });
        }
        return try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });
    }

    pub fn get(self: *HttpClient, path: []const u8) !Response {
        return self.request(.GET, path, null, null);
    }
    pub fn post(self: *HttpClient, path: []const u8, body: ?[]const u8) !Response {
        return self.request(.POST, path, body, null);
    }
    /// POST with `Content-Type: application/x-www-form-urlencoded`.
    pub fn postForm(self: *HttpClient, path: []const u8, body: []const u8) !Response {
        return self.request(.POST, path, body, "application/x-www-form-urlencoded");
    }
    pub fn put(self: *HttpClient, path: []const u8, body: ?[]const u8) !Response {
        return self.request(.PUT, path, body, null);
    }
    pub fn delete(self: *HttpClient, path: []const u8) !Response {
        return self.request(.DELETE, path, null, null);
    }

    pub fn request(self: *HttpClient, method: Method, path: []const u8, body: ?[]const u8, content_type: ?[]const u8) !Response {
        var headers_buf: [1]std.http.Header = undefined;
        const extra: []const std.http.Header = if (content_type) |ct| blk: {
            headers_buf[0] = .{ .name = "content-type", .value = ct };
            break :blk headers_buf[0..1];
        } else &.{};
        return self.requestWith(method, path, body, extra);
    }

    /// POST/GET with arbitrary extra headers (e.g. Authorization for LLM APIs).
    pub fn requestWith(self: *HttpClient, method: Method, path: []const u8, body: ?[]const u8, extra_headers: []const std.http.Header) !Response {
        const url = try self.joinUrl(path);
        defer self.allocator.free(url);

        var body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_writer.deinit();
        var clock = ActivityClock.init(self.threaded.io());
        var activity_writer = ActivityWriter.init(&body_writer.writer, &clock);

        const http_method: std.http.Method = switch (method) {
            .GET => .GET,
            .POST => .POST,
            .PUT => .PUT,
            .DELETE => .DELETE,
        };

        const result = try self.fetchWithTimeout(.{
            .location = .{ .url = url },
            .method = http_method,
            .payload = body,
            .extra_headers = extra_headers,
            .response_writer = &activity_writer.writer,
        }, &clock);

        return .{
            .status = @backingInt(result.status),
            .body = try body_writer.toOwnedSlice(),
            .allocator = self.allocator,
        };
    }

    /// 带空闲超时的 `std.http.Client.fetch`。
    ///
    /// Zig 0.17 的 `fetch` 不支持 timeout：既没有 `FetchOptions.timeout`，
    /// `connectTcpOptions` 的 timeout 也无法穿透 `fetch`。因此在 `std.Io` 层
    /// 把整个请求当作可取消任务，与空闲看门狗竞速（见 `raceWithTimeout`）：
    /// 看门狗先到就取消请求并返回 `error.Timeout`；请求先到就正常返回。
    /// `clock` 由 `ActivityWriter` 在每次响应数据到达时刷新，所以这里是
    /// 「连接 + 读空闲」超时，而不是一刀切的总时长。
    ///
    /// 这里用 `Select.concurrent`（而不是 `async`）：`async` 在 Io 的
    /// `async_limit` 用满时会退化成在调用线程内同步执行，看门狗将永远没机会注册，
    /// 超时也就形同虚设。`concurrent` 要么真正并发、要么明确失败。
    fn fetchWithTimeout(self: *HttpClient, options: std.http.Client.FetchOptions, clock: *ActivityClock) !std.http.Client.FetchResult {
        if (self.timeout_ms == 0) return self.http.fetch(options);
        const result = try raceWithTimeout(self.threaded.io(), self.timeout_ms, clock, fetchTask, .{ self.http, options });
        return result orelse error.Timeout;
    }

    /// Stream the response body via `on_chunk`. `Response.body` is empty (caller still `deinit`s).
    /// Uses `std.http.Client.fetch` with a forwarding writer — chunks arrive as the client drains.
    pub fn requestStream(
        self: *HttpClient,
        method: Method,
        path: []const u8,
        body: ?[]const u8,
        extra_headers: []const std.http.Header,
        cb_ctx: *anyopaque,
        on_chunk: OnBodyChunk,
    ) !Response {
        const url = try self.joinUrl(path);
        defer self.allocator.free(url);

        var forwarder = ChunkForwarder.init(cb_ctx, on_chunk);
        var clock = ActivityClock.init(self.threaded.io());
        var activity_writer = ActivityWriter.init(&forwarder.writer, &clock);

        const http_method: std.http.Method = switch (method) {
            .GET => .GET,
            .POST => .POST,
            .PUT => .PUT,
            .DELETE => .DELETE,
        };

        const result = self.fetchWithTimeout(.{
            .location = .{ .url = url },
            .method = http_method,
            .payload = body,
            .extra_headers = extra_headers,
            .response_writer = &activity_writer.writer,
        }, &clock) catch |err| {
            if (forwarder.cb_err) |e| return e;
            return err;
        };

        return .{
            .status = @backingInt(result.status),
            .body = try self.allocator.dupe(u8, ""),
            .allocator = self.allocator,
        };
    }
};

/// `task_fn` 的薄包装：让 `Select` 的 union 字段类型与任务返回类型一致。
fn fetchTask(client: *std.http.Client, options: std.http.Client.FetchOptions) std.http.Client.FetchError!std.http.Client.FetchResult {
    return client.fetch(options);
}

/// 最近一次收到响应数据的单调时钟（`awake` 时钟，毫秒）。
/// `ActivityWriter` 在每次 `drain` 时刷新它，看门狗据此判断是否真正空闲。
const ActivityClock = struct {
    io: std.Io,
    last_ms: std.atomic.Value(i64),

    fn init(io: std.Io) ActivityClock {
        return .{ .io = io, .last_ms = .init(nowMs(io)) };
    }

    fn touch(self: *ActivityClock) void {
        self.last_ms.store(nowMs(self.io), .monotonic);
    }

    fn idleMs(self: *const ActivityClock) i64 {
        return nowMs(self.io) - self.last_ms.load(.monotonic);
    }
};

fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds();
}

/// 透传 `Writer`：把每次写出的字节原样交给 `target`，同时刷新 `clock`。
/// 这样「收到数据」就等于「还没卡死」，空闲看门狗不必理解 HTTP。
const ActivityWriter = struct {
    target: *std.Io.Writer,
    clock: *ActivityClock,
    writer: std.Io.Writer,

    fn init(target: *std.Io.Writer, clock: *ActivityClock) ActivityWriter {
        return .{
            .target = target,
            .clock = clock,
            .writer = .{ .buffer = &.{}, .vtable = &vtable },
        };
    }

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ActivityWriter = @alignCast(@fieldParentPtr("writer", w));
        self.clock.touch();
        return self.target.vtable.drain(self.target, data, splat);
    }
};

/// 空闲看门狗：只要 `clock` 在 `timeout_ms` 内被刷新过就继续等待；
/// 真正空闲超时后返回，让 `Select` 选中 timeout 分支并取消请求。
fn idleWatchdog(io: std.Io, clock: *ActivityClock, timeout_ms: u64) void {
    const timeout_i: i64 = @intCast(@min(timeout_ms, @as(u64, @intCast(std.math.maxInt(i64)))));
    const poll_i: i64 = @min(timeout_i, 100);
    while (clock.idleMs() < timeout_i) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@max(poll_i, 1)), .awake) catch return;
    }
}

/// 让 `task_fn` 与空闲看门狗竞速：请求先完成返回其结果（`?Ret`），空闲超时返回 `null`。
///
/// 依赖 `std.Io.Select` + `concurrent`：两个任务都真正并发执行，超时后
/// `cancelDiscard` 会取消未完成的一方并等待其清理（包括 `fetch` 的 `defer`）。
fn raceWithTimeout(
    io: std.Io,
    timeout_ms: u64,
    clock: *ActivityClock,
    comptime task_fn: anytype,
    task_args: std.meta.ArgsTuple(@TypeOf(task_fn)),
) !?@typeInfo(@TypeOf(task_fn)).@"fn".return_type.? {
    const Ret = @typeInfo(@TypeOf(task_fn)).@"fn".return_type.?;

    const Outcome = union(enum) {
        task: Ret,
        timeout: void,
    };
    var buf: [2]Outcome = undefined;
    var select: std.Io.Select(Outcome) = .init(io, &buf);
    defer select.cancelDiscard();

    try select.concurrent(.task, task_fn, task_args);
    try select.concurrent(.timeout, idleWatchdog, .{ io, clock, timeout_ms });

    return switch (try select.await()) {
        .task => |result| result,
        .timeout => null,
    };
}

/// `std.Io.Writer` that invokes `OnBodyChunk` from `drain` (unbuffered).
const ChunkForwarder = struct {
    ctx: *anyopaque,
    on_chunk: HttpClient.OnBodyChunk,
    writer: std.Io.Writer,
    cb_err: ?anyerror = null,

    fn init(ctx: *anyopaque, on_chunk: HttpClient.OnBodyChunk) ChunkForwarder {
        return .{
            .ctx = ctx,
            .on_chunk = on_chunk,
            .writer = .{
                .buffer = &.{},
                .vtable = &vtable,
            },
        };
    }

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
    };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ChunkForwarder = @alignCast(@fieldParentPtr("writer", w));
        w.end = 0;
        var written: usize = 0;
        const slice = data[0 .. data.len - 1];
        const pattern = data[data.len - 1];
        for (slice) |bytes| {
            self.on_chunk(self.ctx, bytes) catch |err| {
                self.cb_err = err;
                return error.WriteFailed;
            };
            written += bytes.len;
        }
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            self.on_chunk(self.ctx, pattern) catch |err| {
                self.cb_err = err;
                return error.WriteFailed;
            };
            written += pattern.len;
        }
        return written;
    }
};

test "http client: joinUrl" {
    const a = std.testing.allocator;
    var c = try HttpClient.init(a, "http://example.com/api");
    defer c.deinit();
    const joined = try c.joinUrl("/v1");
    defer a.free(joined);
    try std.testing.expectEqualStrings("http://example.com/api/v1", joined);
    const abs = try c.joinUrl("http://other/x");
    defer a.free(abs);
    try std.testing.expectEqualStrings("http://other/x", abs);
}

test "http client: ChunkForwarder drain invokes on_chunk" {
    const Ctx = struct {
        total: usize = 0,
        fn onChunk(ctx: *anyopaque, chunk: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.total += chunk.len;
        }
    };
    var ctx = Ctx{};
    var fwd = ChunkForwarder.init(&ctx, Ctx.onChunk);
    const parts = [_][]const u8{ "ab", "c" };
    const n = try ChunkForwarder.drain(&fwd.writer, &parts, 1);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(usize, 3), ctx.total);
}

test "http client: ActivityWriter forwards bytes and refreshes the idle clock" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var clock = ActivityClock.init(io);
    // 人为制造空闲，再写入，验证写入会刷新计时。
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(30), .awake) catch {};
    const idle_before = clock.idleMs();
    try std.testing.expect(idle_before >= 20);

    var sink: std.Io.Writer.Allocating = .init(a);
    defer sink.deinit();
    var aw = ActivityWriter.init(&sink.writer, &clock);
    try aw.writer.writeAll("hello");

    try std.testing.expectEqualStrings("hello", sink.written());
    try std.testing.expect(clock.idleMs() < idle_before);
}

test "http client: raceWithTimeout cancels a slow task and reports timeout" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var clock = ActivityClock.init(io);

    const Slow = struct {
        fn run(task_io: std.Io) u32 {
            std.Io.sleep(task_io, std.Io.Duration.fromMilliseconds(10_000), .awake) catch return 0;
            return 1;
        }
    };

    // 始终空闲 -> null（调用方据此返回 error.Timeout），慢任务被取消。
    try std.testing.expectEqual(@as(?u32, null), try raceWithTimeout(io, 50, &clock, Slow.run, .{io}));
}

test "http client: raceWithTimeout returns the task result when it finishes first" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var clock = ActivityClock.init(io);

    const Fast = struct {
        fn run() u32 {
            return 7;
        }
    };

    try std.testing.expectEqual(@as(?u32, 7), try raceWithTimeout(io, 5_000, &clock, Fast.run, .{}));
}

test "http client: idle timeout is refreshed by ongoing activity" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var clock = ActivityClock.init(io);

    const Busy = struct {
        fn run(task_io: std.Io, c: *ActivityClock) u32 {
            var i: usize = 0;
            while (i < 5) : (i += 1) {
                std.Io.sleep(task_io, std.Io.Duration.fromMilliseconds(20), .awake) catch return 0;
                c.touch();
            }
            return 42;
        }
    };

    // 每 20ms 刷新一次、总耗时约 100ms；50ms 的空闲阈值不应触发。
    try std.testing.expectEqual(@as(?u32, 42), try raceWithTimeout(io, 50, &clock, Busy.run, .{ io, &clock }));
}
