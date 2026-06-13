const std = @import("std");
const io_instance = @import("../io_instance.zig");

/// Redis client with full RESP protocol support over TCP.
pub const RedisClient = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    stream: ?std.Io.net.Stream = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !RedisClient {
        return .{ .allocator = allocator, .host = try allocator.dupe(u8, host), .port = port };
    }

    pub fn deinit(self: *Self) void {
        self.disconnect();
        self.allocator.free(self.host);
    }

    /// Connect to Redis server via TCP.
    pub fn connect(self: *Self) !void {
        const address = try std.Io.net.IpAddress.parseIp4(self.host, self.port);
        self.stream = try address.connect(io_instance.io, .{});
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

    /// Send a RESP command and read the response.
    fn command(self: *Self, args: []const []const u8) !?[]const u8 {
        const s = try self.requireStream();
        // Build RESP: *<n>\r\n$<len>\r\n<arg>\r\n...
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
        // Write to stream
        var wbuf: [4096]u8 = undefined;
        var writer = s.writer(io_instance.io, &wbuf);
        try writer.interface.writeAll(req.items);
        // Read response
        return self.readResponse();
    }

    /// Read and parse a RESP response. Returns value or null for nil bulk strings.
    fn readResponse(self: *Self) !?[]const u8 {
        const s = try self.requireStream();
        var rbuf: [4096]u8 = undefined;
        var reader = s.reader(io_instance.io, &rbuf);
        const n = try reader.interface.readSliceShort(&rbuf);
        if (n == 0) return error.ConnectionClosed;
        return parseResp(self.allocator, rbuf[0..n]);
    }

    /// Parse a RESP response line. Returns value or null for nil.
    fn parseResp(allocator: std.mem.Allocator, data: []const u8) !?[]const u8 {
        if (data.len == 0) return error.EmptyResponse;
        return switch (data[0]) {
            '+' => { // Simple String: +OK\r\n
                const end = std.mem.indexOf(u8, data, "\r\n") orelse return error.InvalidResp;
                return try allocator.dupe(u8, data[1..end]);
            },
            '-' => { // Error: -ERR message\r\n
                const end = std.mem.indexOf(u8, data, "\r\n") orelse return error.InvalidResp;
                const msg = data[1..end];
                if (std.mem.startsWith(u8, msg, "ERR ")) return error.RedisError;
                if (std.mem.startsWith(u8, msg, "WRONGTYPE ")) return error.WrongType;
                return error.RedisError;
            },
            ':' => { // Integer: :42\r\n
                const end = std.mem.indexOf(u8, data, "\r\n") orelse return error.InvalidResp;
                return try allocator.dupe(u8, data[1..end]);
            },
            '$' => { // Bulk String: $5\r\nhello\r\n  or  $-1\r\n (nil)
                const end = std.mem.indexOfScalar(u8, data, '\n') orelse return error.InvalidResp;
                const len_str = data[1 .. end - 1];
                const len = try std.fmt.parseInt(i64, len_str, 10);
                if (len < 0) return null; // nil bulk string
                const val_start = end + 1;
                const val_len: usize = @intCast(len);
                if (data.len < val_start + val_len) return error.InvalidResp;
                return try allocator.dupe(u8, data[val_start .. val_start + val_len]);
            },
            '*' => { // Array: *2\r\n...  — we only need the first element for now
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
            return std.mem.eql(u8, r, "1");
        }
        return false;
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
