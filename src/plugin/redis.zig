const std = @import("std");
const io_instance = @import("../io_instance.zig");
const sockread = @import("../core/sockread.zig");

/// Redis client with RESP protocol support over TCP.
/// Reads responses by accumulating until a complete RESP value is available
/// (handles bulk strings larger than a single socket read). Cap via max_response_bytes.
pub const RedisClient = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    stream: ?std.Io.net.Stream = null,
    /// Hard cap on a single response body to avoid unbounded allocation.
    max_response_bytes: usize = 4 * 1024 * 1024,
    /// Soft deadline for connect + first PING (ms). Zig Threaded has no dial
    /// timeout; we connect then require a PING reply within this window.
    connect_timeout_ms: u64 = 5_000,
    /// Soft deadline for subsequent command reads (ms). 0 = unlimited.
    command_timeout_ms: u64 = 5_000,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !RedisClient {
        return .{ .allocator = allocator, .host = try allocator.dupe(u8, host), .port = port };
    }

    pub fn deinit(self: *Self) void {
        self.disconnect();
        self.allocator.free(self.host);
    }

    /// Connect to Redis server via TCP, then PING within `connect_timeout_ms`.
    pub fn connect(self: *Self) !void {
        const address = try std.Io.net.IpAddress.parseIp4(self.host, self.port);
        self.stream = try address.connect(io_instance.io, .{ .mode = .stream });
        errdefer self.disconnect();
        // Application-level deadline: require a PING round-trip.
        const deadline = nowMillis() + @as(i64, @intCast(self.connect_timeout_ms));
        const pong = self.commandWithDeadline(&.{"PING"}, deadline) catch |err| switch (err) {
            error.Timeout => return error.ConnectTimeout,
            else => return err,
        };
        defer if (pong) |p| self.allocator.free(p);
        if (pong == null or !std.mem.eql(u8, pong.?, "PONG")) return error.ConnectTimeout;
    }

    /// Disconnect from Redis server.
    pub fn disconnect(self: *Self) void {
        if (self.stream) |s| {
            s.close(io_instance.io);
            self.stream = null;
        }
    }

    fn requireStream(self: *Self) !*std.Io.net.Stream {
        return &(self.stream orelse return error.NotConnected);
    }

    fn nowMillis() i64 {
        return std.Io.Timestamp.now(io_instance.io, .real).toMilliseconds();
    }

    /// Send a RESP command and read the response (uses `command_timeout_ms`).
    fn command(self: *Self, args: []const []const u8) !?[]const u8 {
        const deadline: ?i64 = if (self.command_timeout_ms == 0)
            null
        else
            nowMillis() + @as(i64, @intCast(self.command_timeout_ms));
        return self.commandWithDeadline(args, deadline);
    }

    fn commandWithDeadline(self: *Self, args: []const []const u8, deadline: ?i64) !?[]const u8 {
        const s = try self.requireStream();
        var req = std.ArrayList(u8).empty;
        defer req.deinit(self.allocator);
        const n_str = try std.fmt.allocPrint(self.allocator, "*{d}\r\n", .{args.len});
        defer self.allocator.free(n_str);
        try req.appendSlice(self.allocator, n_str);
        for (args) |arg| {
            const hdr = try std.fmt.allocPrint(self.allocator, "${d}\r\n", .{arg.len});
            defer self.allocator.free(hdr);
            try req.appendSlice(self.allocator, hdr);
            try req.appendSlice(self.allocator, arg);
            try req.appendSlice(self.allocator, "\r\n");
        }
        var wbuf: [4096]u8 = undefined;
        var writer = s.writer(io_instance.io, &wbuf);
        try writer.interface.writeAll(req.items);
        // `writeAll` only fills the 4 KiB buffer; commands are far smaller than
        // that, so without an explicit flush the request never hits the socket
        // and the read below waits for a reply that was never requested.
        try writer.interface.flush();
        return self.readResponseDeadline(deadline);
    }

    /// Read and parse a RESP response, looping until a complete value arrives.
    fn readResponse(self: *Self) !?[]const u8 {
        return self.readResponseDeadline(null);
    }

    fn readResponseDeadline(self: *Self, deadline: ?i64) !?[]const u8 {
        const s = try self.requireStream();
        var accum = std.ArrayList(u8).empty;
        defer accum.deinit(self.allocator);

        var rbuf: [4096]u8 = undefined;

        while (true) {
            if (accum.items.len >= self.max_response_bytes) return error.ResponseTooLarge;

            // One posix read via sockread (bypasses shared Threaded Io hang).
            // Short reads are fine — RESP is reassembled in `accum`.
            const timeout: i32 = if (deadline) |d| blk: {
                const rem = d - nowMillis();
                if (rem <= 0) return error.Timeout;
                break :blk @intCast(@min(rem, std.math.maxInt(i32)));
            } else -1;

            const n = sockread.readSomeTimeout(s.*, &rbuf, timeout) catch |err| switch (err) {
                error.Timeout => return error.Timeout,
                error.ConnectionError => return error.ConnectionClosed,
            };
            if (n == 0) {
                if (accum.items.len == 0) return error.ConnectionClosed;
                return error.IncompleteResponse;
            }

            const take_n = @min(n, self.max_response_bytes - accum.items.len);
            try accum.appendSlice(self.allocator, rbuf[0..take_n]);

            const parsed = parseResp(self.allocator, accum.items) catch |err| switch (err) {
                error.NeedMoreData => continue,
                else => return err,
            };
            return parsed;
        }
    }

    /// Parse a RESP response. Returns value or null for nil bulk strings.
    /// Returns error.NeedMoreData when the buffer does not yet contain a full value.
    pub fn parseResp(allocator: std.mem.Allocator, data: []const u8) !?[]const u8 {
        if (data.len == 0) return error.NeedMoreData;
        return switch (data[0]) {
            '+' => { // Simple String: +OK\r\n
                const end = std.mem.indexOf(u8, data, "\r\n") orelse return error.NeedMoreData;
                return try allocator.dupe(u8, data[1..end]);
            },
            '-' => { // Error: -ERR message\r\n
                const end = std.mem.indexOf(u8, data, "\r\n") orelse return error.NeedMoreData;
                const msg = data[1..end];
                if (std.mem.startsWith(u8, msg, "ERR ")) return error.RedisError;
                if (std.mem.startsWith(u8, msg, "WRONGTYPE ")) return error.WrongType;
                return error.RedisError;
            },
            ':' => { // Integer: :42\r\n
                const end = std.mem.indexOf(u8, data, "\r\n") orelse return error.NeedMoreData;
                return try allocator.dupe(u8, data[1..end]);
            },
            '$' => { // Bulk String: $5\r\nhello\r\n  or  $-1\r\n (nil)
                const end = std.mem.indexOf(u8, data, "\r\n") orelse return error.NeedMoreData;
                const len_str = data[1..end];
                const len = try std.fmt.parseInt(i64, len_str, 10);
                if (len < 0) return null; // nil bulk string
                const val_start = end + 2;
                const val_len: usize = @intCast(len);
                // Need payload + trailing \r\n
                if (data.len < val_start + val_len + 2) return error.NeedMoreData;
                return try allocator.dupe(u8, data[val_start .. val_start + val_len]);
            },
            '*' => { // Array: *N\r\n... — wait for at least the header line
                _ = std.mem.indexOf(u8, data, "\r\n") orelse return error.NeedMoreData;
                // Full array reassembly is out of scope; return empty for subscribe acks etc.
                return try allocator.dupe(u8, "");
            },
            else => return error.InvalidResp,
        };
    }

    /// PING command.
    pub fn ping(self: *Self) bool {
        const result = self.command(&.{"PING"}) catch return false;
        if (result) |r| {
            defer self.allocator.free(r);
            return std.mem.eql(u8, r, "PONG");
        }
        return false;
    }

    /// GET key. Returns value or null.
    pub fn get(self: *Self, key: []const u8) !?[]const u8 {
        return self.command(&.{ "GET", key });
    }

    /// SET key value.
    pub fn set(self: *Self, key: []const u8, value: []const u8) !void {
        const result = try self.command(&.{ "SET", key, value });
        if (result) |r| self.allocator.free(r);
    }

    /// SET key value EX seconds.
    pub fn setEx(self: *Self, key: []const u8, value: []const u8, ttl_sec: u64) !void {
        var ttl_buf: [32]u8 = undefined;
        const ttl_str = try std.fmt.bufPrint(&ttl_buf, "{d}", .{ttl_sec});
        const result = try self.command(&.{ "SETEX", key, ttl_str, value });
        if (result) |r| self.allocator.free(r);
    }

    /// DEL key.
    pub fn del(self: *Self, key: []const u8) !void {
        const result = try self.command(&.{ "DEL", key });
        if (result) |r| self.allocator.free(r);
    }

    /// EXISTS key. Returns true if the key exists.
    pub fn exists(self: *Self, key: []const u8) !bool {
        const result = try self.command(&.{ "EXISTS", key });
        if (result) |r| {
            defer self.allocator.free(r);
            // parseResp strips the ':' prefix from RESP integers.
            return std.mem.eql(u8, r, "1");
        }
        return false;
    }

    /// PUBLISH channel message. Returns the number of subscribers
    /// that received the message.
    pub fn publish(self: *Self, channel: []const u8, message: []const u8) !i64 {
        const result = try self.command(&.{ "PUBLISH", channel, message });
        if (result) |r| {
            defer self.allocator.free(r);
            return std.fmt.parseInt(i64, r, 10) catch 0;
        }
        return 0;
    }

    /// SUBSCRIBE channel. Enters pub/sub mode; subsequent reads
    /// will receive messages on subscribed channels.
    pub fn subscribe(self: *Self, channel: []const u8) !void {
        _ = try self.command(&.{ "SUBSCRIBE", channel });
    }

    /// EXPIRE key seconds.
    pub fn expire(self: *Self, key: []const u8, ttl_sec: u64) !void {
        var ttl_buf: [32]u8 = undefined;
        const ttl_str = try std.fmt.bufPrint(&ttl_buf, "{d}", .{ttl_sec});
        const result = try self.command(&.{ "EXPIRE", key, ttl_str });
        if (result) |r| self.allocator.free(r);
    }

    /// FLUSHDB — clear current database.
    pub fn flushDb(self: *Self) !void {
        const result = try self.command(&.{"FLUSHDB"});
        if (result) |r| self.allocator.free(r);
    }
};

/// Redis-backed cache implementation.
pub const RedisCache = struct {
    client: RedisClient,
    default_ttl: u64 = 300,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !RedisCache {
        var client = try RedisClient.init(allocator, host, port);
        try client.connect();
        return .{ .client = client };
    }

    pub fn deinit(self: *Self) void {
        self.client.deinit();
    }

    pub fn get(self: *Self, key: []const u8) !?[]const u8 {
        return self.client.get(key);
    }

    pub fn set(self: *Self, key: []const u8, value: []const u8, ttl: ?u64) !void {
        if (ttl) |t| {
            try self.client.setEx(key, value, t);
        } else {
            try self.client.setEx(key, value, self.default_ttl);
        }
    }

    pub fn delete(self: *Self, key: []const u8) !void {
        try self.client.del(key);
    }

    pub fn clear(self: *Self) !void {
        try self.client.flushDb();
    }
};

test "redis: parseResp simple string" {
    const a = std.testing.allocator;
    const v = try RedisClient.parseResp(a, "+PONG\r\n");
    defer if (v) |r| a.free(r);
    try std.testing.expectEqualStrings("PONG", v.?);
}

test "redis: parseResp integer strips colon" {
    const a = std.testing.allocator;
    const v = try RedisClient.parseResp(a, ":1\r\n");
    defer if (v) |r| a.free(r);
    try std.testing.expectEqualStrings("1", v.?);
}

test "redis: parseResp bulk string" {
    const a = std.testing.allocator;
    const v = try RedisClient.parseResp(a, "$5\r\nhello\r\n");
    defer if (v) |r| a.free(r);
    try std.testing.expectEqualStrings("hello", v.?);
}

test "redis: parseResp bulk NeedMoreData" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.NeedMoreData, RedisClient.parseResp(a, "$5\r\nhel"));
}

test "redis: parseResp nil bulk" {
    const a = std.testing.allocator;
    const v = try RedisClient.parseResp(a, "$-1\r\n");
    try std.testing.expect(v == null);
}
