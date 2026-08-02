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

        const http_method: std.http.Method = switch (method) {
            .GET => .GET,
            .POST => .POST,
            .PUT => .PUT,
            .DELETE => .DELETE,
        };

        const result = try self.http.fetch(.{
            .location = .{ .url = url },
            .method = http_method,
            .payload = body,
            .extra_headers = extra_headers,
            .response_writer = &body_writer.writer,
        });

        return .{
            .status = @intFromEnum(result.status),
            .body = try body_writer.toOwnedSlice(),
            .allocator = self.allocator,
        };
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

        const http_method: std.http.Method = switch (method) {
            .GET => .GET,
            .POST => .POST,
            .PUT => .PUT,
            .DELETE => .DELETE,
        };

        const result = self.http.fetch(.{
            .location = .{ .url = url },
            .method = http_method,
            .payload = body,
            .extra_headers = extra_headers,
            .response_writer = &forwarder.writer,
        }) catch |err| {
            if (forwarder.cb_err) |e| return e;
            return err;
        };

        return .{
            .status = @intFromEnum(result.status),
            .body = try self.allocator.dupe(u8, ""),
            .allocator = self.allocator,
        };
    }
};

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
