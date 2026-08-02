//! MCP HTTP / SSE transport (Streamable HTTP style).
//! Each `writeMessage` POSTs one JSON-RPC body; response is application/json
//! or `text/event-stream` (`data:` lines). Inject `postFn` for unit tests.

const std = @import("std");
const mcp_client = @import("mcp_client.zig");

pub const Transport = mcp_client.Transport;
pub const McpClient = mcp_client.McpClient;

pub const HttpOpts = struct {
    /// Extra request headers (borrowed; e.g. Authorization).
    headers: []const std.http.Header = &.{},
    /// Accept both JSON and SSE (MCP streamable HTTP).
    accept: []const u8 = "application/json, text/event-stream",
};

/// `postFn` returns owned response body (caller frees). Empty body = accepted notification.
pub const HttpPostFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, json: []const u8) anyerror![]u8;

pub const HttpTransport = struct {
    allocator: std.mem.Allocator,
    post_ctx: *anyopaque,
    postFn: HttpPostFn,
    pending: std.ArrayList([]u8) = .empty,
    closed: bool = false,
    owns_close_destroy: bool = false,

    pub fn init(allocator: std.mem.Allocator, post_ctx: *anyopaque, postFn: HttpPostFn) HttpTransport {
        return .{ .allocator = allocator, .post_ctx = post_ctx, .postFn = postFn };
    }

    pub fn deinit(self: *HttpTransport) void {
        for (self.pending.items) |m| self.allocator.free(m);
        self.pending.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn transport(self: *HttpTransport) Transport {
        return .{
            .ptr = self,
            .writeMessageFn = writeMessage,
            .readMessageFn = readMessage,
            .closeFn = close,
        };
    }

    fn writeMessage(ptr: *anyopaque, json: []const u8) anyerror!void {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));
        if (self.closed) return error.TransportClosed;
        const body = try self.postFn(self.post_ctx, self.allocator, json);
        defer self.allocator.free(body);
        if (body.len == 0) return;
        try enqueueFromHttpBody(self.allocator, &self.pending, body);
    }

    fn readMessage(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));
        if (self.closed) return error.TransportClosed;
        if (self.pending.items.len == 0) return error.NoResponse;
        const msg = self.pending.orderedRemove(0);
        defer self.allocator.free(msg);
        return try allocator.dupe(u8, msg);
    }

    fn close(ptr: *anyopaque) void {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));
        self.closed = true;
        const destroy = self.owns_close_destroy;
        const alloc = self.allocator;
        self.deinit();
        if (destroy) alloc.destroy(self);
    }
};

/// Parse application/json or SSE `data:` payloads into JSON-RPC message bodies.
pub fn parseMcpHttpBody(allocator: std.mem.Allocator, body: []const u8) ![][]u8 {
    var list = std.ArrayList([]u8).empty;
    errdefer {
        for (list.items) |m| allocator.free(m);
        list.deinit(allocator);
    }
    try enqueueFromHttpBody(allocator, &list, body);
    return try list.toOwnedSlice(allocator);
}

fn enqueueFromHttpBody(allocator: std.mem.Allocator, pending: *std.ArrayList([]u8), body: []const u8) !void {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return;

    // Bare JSON object / array
    if (trimmed[0] == '{' or trimmed[0] == '[') {
        try pending.append(allocator, try allocator.dupe(u8, trimmed));
        return;
    }

    // SSE: collect data: lines (ignore event:/id:/comment)
    var data_buf = std.ArrayList(u8).empty;
    defer data_buf.deinit(allocator);

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) {
            if (data_buf.items.len > 0) {
                const payload = std.mem.trim(u8, data_buf.items, " \t");
                if (payload.len > 0 and !std.mem.eql(u8, payload, "[DONE]")) {
                    try pending.append(allocator, try allocator.dupe(u8, payload));
                }
                data_buf.clearRetainingCapacity();
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "data:")) {
            var rest = line["data:".len..];
            if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
            if (data_buf.items.len > 0) try data_buf.append(allocator, '\n');
            try data_buf.appendSlice(allocator, rest);
        }
    }
    if (data_buf.items.len > 0) {
        const payload = std.mem.trim(u8, data_buf.items, " \t");
        if (payload.len > 0 and !std.mem.eql(u8, payload, "[DONE]")) {
            try pending.append(allocator, try allocator.dupe(u8, payload));
        }
    }
}

/// Live HTTP transport owning `std.http.Client` + Threaded Io.
const LiveHttp = struct {
    allocator: std.mem.Allocator,
    threaded: *std.Io.Threaded,
    http: *std.http.Client,
    url: []u8,
    /// Owned "Name: value" pairs flattened into Header slice rebuild each request.
    header_names: [][]u8,
    header_values: [][]u8,
    accept: []u8,
    transport_box: *HttpTransport,

    fn post(ctx: *anyopaque, allocator: std.mem.Allocator, json: []const u8) anyerror![]u8 {
        const self: *LiveHttp = @ptrCast(@alignCast(ctx));
        _ = allocator;

        var headers_buf: [16]std.http.Header = undefined;
        var n: usize = 0;
        headers_buf[n] = .{ .name = "content-type", .value = "application/json" };
        n += 1;
        headers_buf[n] = .{ .name = "accept", .value = self.accept };
        n += 1;
        var i: usize = 0;
        while (i < self.header_names.len) : (i += 1) {
            if (n >= headers_buf.len) return error.TooManyHeaders;
            headers_buf[n] = .{ .name = self.header_names[i], .value = self.header_values[i] };
            n += 1;
        }

        var body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_writer.deinit();

        const result = try self.http.fetch(.{
            .location = .{ .url = self.url },
            .method = .POST,
            .payload = json,
            .extra_headers = headers_buf[0..n],
            .response_writer = &body_writer.writer,
        });
        const status = @intFromEnum(result.status);
        if (status == 202 or status == 204) {
            return try self.allocator.dupe(u8, "");
        }
        if (status < 200 or status >= 300) return error.HttpStatusError;
        return try body_writer.toOwnedSlice();
    }

    fn destroy(self: *LiveHttp) void {
        self.http.deinit();
        self.allocator.destroy(self.http);
        self.threaded.deinit();
        self.allocator.destroy(self.threaded);
        self.allocator.free(self.url);
        self.allocator.free(self.accept);
        for (self.header_names) |s| self.allocator.free(s);
        for (self.header_values) |s| self.allocator.free(s);
        self.allocator.free(self.header_names);
        self.allocator.free(self.header_values);
        // transport_box closed separately via Transport.close
        self.allocator.destroy(self);
    }
};

/// Connect MCP over HTTP POST (JSON or SSE response). Caller `deinit`s the client.
pub fn connect(allocator: std.mem.Allocator, io: std.Io, url: []const u8, opts: HttpOpts) !McpClient {
    _ = io; // Threaded Io owned inside LiveHttp
    const live = try allocator.create(LiveHttp);
    errdefer allocator.destroy(live);

    const threaded = try allocator.create(std.Io.Threaded);
    errdefer allocator.destroy(threaded);
    threaded.* = std.Io.Threaded.init(allocator, .{});
    errdefer threaded.deinit();

    const http = try allocator.create(std.http.Client);
    errdefer allocator.destroy(http);
    http.* = .{ .allocator = allocator, .io = threaded.io() };
    errdefer http.deinit();

    const url_owned = try allocator.dupe(u8, url);
    errdefer allocator.free(url_owned);
    const accept_owned = try allocator.dupe(u8, opts.accept);
    errdefer allocator.free(accept_owned);

    var names = try allocator.alloc([]u8, opts.headers.len);
    errdefer {
        for (names) |s| allocator.free(s);
        allocator.free(names);
    }
    var values = try allocator.alloc([]u8, opts.headers.len);
    errdefer {
        for (values) |s| allocator.free(s);
        allocator.free(values);
    }
    @memset(names, &.{});
    @memset(values, &.{});
    for (opts.headers, 0..) |h, i| {
        names[i] = try allocator.dupe(u8, h.name);
        values[i] = try allocator.dupe(u8, h.value);
    }

    const tbox = try allocator.create(HttpTransport);
    errdefer allocator.destroy(tbox);

    live.* = .{
        .allocator = allocator,
        .threaded = threaded,
        .http = http,
        .url = url_owned,
        .header_names = names,
        .header_values = values,
        .accept = accept_owned,
        .transport_box = tbox,
    };

    tbox.* = HttpTransport.init(allocator, live, LiveHttp.post);
    tbox.owns_close_destroy = true;

    // Wrap close to also destroy LiveHttp
    return .{
        .allocator = allocator,
        .io = threaded.io(),
        .mutex = .init,
        .transport = .{
            .ptr = tbox,
            .writeMessageFn = HttpTransport.writeMessage,
            .readMessageFn = HttpTransport.readMessage,
            .closeFn = closeLive,
        },
        .owns_transport_close = true,
        .pending_by_id = std.AutoHashMap(i64, []u8).init(allocator),
    };
}

fn closeLive(ptr: *anyopaque) void {
    const tbox: *HttpTransport = @ptrCast(@alignCast(ptr));
    const live: *LiveHttp = @ptrCast(@alignCast(tbox.post_ctx));
    tbox.closed = true;
    const alloc = tbox.allocator;
    for (tbox.pending.items) |m| alloc.free(m);
    tbox.pending.deinit(alloc);
    alloc.destroy(tbox);
    live.destroy();
}

test "parseMcpHttpBody JSON and SSE" {
    const a = std.testing.allocator;
    const one = try parseMcpHttpBody(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}");
    defer {
        for (one) |m| a.free(m);
        a.free(one);
    }
    try std.testing.expectEqual(@as(usize, 1), one.len);

    const sse =
        \\event: message
        \\data: {"jsonrpc":"2.0","id":2,"result":{"ok":true}}
        \\
        \\data: {"jsonrpc":"2.0","method":"notifications/progress"}
        \\
    ;
    const many = try parseMcpHttpBody(a, sse);
    defer {
        for (many) |m| a.free(m);
        a.free(many);
    }
    try std.testing.expectEqual(@as(usize, 2), many.len);

    const arr_sse =
        \\data: [{"jsonrpc":"2.0","id":1,"result":{}}]
        \\
    ;
    const arr = try parseMcpHttpBody(a, arr_sse);
    defer {
        for (arr) |m| a.free(m);
        a.free(arr);
    }
    try std.testing.expectEqual(@as(usize, 1), arr.len);
    try std.testing.expect(arr[0][0] == '[');
}

test "HttpTransport FakePost roundtrip" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Fake = struct {
        fn methodIs(json: []const u8, method: []const u8) bool {
            // Match "method":"<name>" exactly — do NOT use indexOf("initialize"),
            // which falsely hits inside "notifications/initialized".
            var needle_buf: [96]u8 = undefined;
            const needle = std.fmt.bufPrint(&needle_buf, "\"method\":\"{s}\"", .{method}) catch return false;
            return std.mem.indexOf(u8, json, needle) != null;
        }

        fn extractId(json: []const u8) i64 {
            const key = "\"id\":";
            const idx = std.mem.indexOf(u8, json, key) orelse return 1;
            var i = idx + key.len;
            while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}
            var n: i64 = 0;
            var any = false;
            while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) {
                n = n * 10 + (json[i] - '0');
                any = true;
            }
            return if (any) n else 1;
        }

        fn post(ctx: *anyopaque, allocator: std.mem.Allocator, json: []const u8) anyerror![]u8 {
            _ = ctx;
            if (methodIs(json, "initialize")) {
                const id = extractId(json);
                return try std.fmt.allocPrint(allocator,
                    \\{{"jsonrpc":"2.0","id":{d},"result":{{"protocolVersion":"2024-11-05","capabilities":{{}},"serverInfo":{{"name":"http","version":"1"}}}}}}
                , .{id});
            }
            if (methodIs(json, "notifications/initialized")) {
                return try allocator.dupe(u8, "");
            }
            if (methodIs(json, "tools/list")) {
                const id = extractId(json);
                return try std.fmt.allocPrint(allocator,
                    \\data: {{"jsonrpc":"2.0","id":{d},"result":{{"tools":[]}}}}
                    \\
                , .{id});
            }
            return error.Unexpected;
        }
    };
    var unused: u8 = 0;
    var ht = HttpTransport.init(a, &unused, Fake.post);
    defer {
        ht.owns_close_destroy = false;
        for (ht.pending.items) |m| a.free(m);
        ht.pending.deinit(a);
    }

    var client = McpClient.initWithTransport(a, io, ht.transport());
    defer {
        client.owns_transport_close = false;
        client.deinit();
    }
    try client.initialize();
    const tools = try client.listTools();
    defer client.freeTools(tools);
    try std.testing.expectEqual(@as(usize, 0), tools.len);
}

test "FakePost does not confuse initialize with initialized" {
    // Regression: substring "initialize" appears inside "initialized".
    const notif = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}";
    try std.testing.expect(std.mem.indexOf(u8, notif, "initialize") != null);

    const Fake = struct {
        fn methodIs(json: []const u8, method: []const u8) bool {
            var needle_buf: [96]u8 = undefined;
            const needle = std.fmt.bufPrint(&needle_buf, "\"method\":\"{s}\"", .{method}) catch return false;
            return std.mem.indexOf(u8, json, needle) != null;
        }
    };
    try std.testing.expect(!Fake.methodIs(notif, "initialize"));
    try std.testing.expect(Fake.methodIs(notif, "notifications/initialized"));
    try std.testing.expect(Fake.methodIs(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    , "initialize"));
}
