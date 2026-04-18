const std = @import("std");
const net = std.net;

/// Simple Redis client for ZFinal cache system
/// Supports basic operations: GET, SET, DEL, EXPIRE, EXISTS
pub const RedisClient = struct {
    allocator: std.mem.Allocator,
    stream: ?net.Stream = null,
    connected: bool = false,
    host: []const u8,
    port: u16,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !RedisClient {
        return RedisClient{
            .allocator = allocator,
            .host = try allocator.dupe(u8, host),
            .port = port,
        };
    }

    pub fn deinit(self: *Self) void {
        self.disconnect();
        self.allocator.free(self.host);
    }

    /// Connect to Redis server
    pub fn connect(self: *Self) !void {
        if (self.connected) return;

        const address = try net.Address.parseIp4(self.host, self.port);
        self.stream = try net.tcpConnectToAddress(address);
        self.connected = true;
    }

    /// Disconnect from Redis server
    pub fn disconnect(self: *Self) void {
        if (self.stream) |stream| {
            stream.close();
            self.stream = null;
        }
        self.connected = false;
    }

    /// Send Redis command and get response
    fn sendCommand(self: *Self, command: []const u8) ![]const u8 {
        if (!self.connected) try self.connect();
        const stream = self.stream.?;

        try stream.writeAll(command);

        // Read response
        var buffer: [4096]u8 = undefined;
        const bytes_read = try stream.read(&buffer);
        if (bytes_read == 0) return error.ConnectionClosed;

        return try self.allocator.dupe(u8, buffer[0..bytes_read]);
    }

    /// Build Redis protocol command (RESP)
    fn buildCommand(self: *Self, parts: []const []const u8) ![]const u8 {
        var cmd = std.ArrayList(u8).empty;
        errdefer cmd.deinit(self.allocator);

        // Array header
        try cmd.appendSlice(self.allocator, "*");
        try cmd.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "{d}", .{parts.len}));
        try cmd.appendSlice(self.allocator, "\r\n");
        self.allocator.free(cmd.items[cmd.items.len - parts.len - 1 ..]); // Clean up

        // Actually, let's build it properly
        cmd.deinit(self.allocator);
        cmd = std.ArrayList(u8).empty;

        const header = try std.fmt.allocPrint(self.allocator, "*{d}\r\n", .{parts.len});
        defer self.allocator.free(header);
        try cmd.appendSlice(self.allocator, header);

        for (parts) |part| {
            const line = try std.fmt.allocPrint(self.allocator, "${d}\r\n{s}\r\n", .{ part.len, part });
            defer self.allocator.free(line);
            try cmd.appendSlice(self.allocator, line);
        }

        return cmd.toOwnedSlice();
    }

    /// Parse simple string response
    fn parseResponse(self: *Self, response: []const u8) !?[]const u8 {
        defer self.allocator.free(response);

        if (response.len == 0) return null;

        switch (response[0]) {
            '+' => {
                // Simple string
                const end = std.mem.indexOf(u8, response, "\r\n") orelse response.len;
                return try self.allocator.dupe(u8, response[1..end]);
            },
            '-' => {
                // Error
                const end = std.mem.indexOf(u8, response, "\r\n") orelse response.len;
                std.debug.print("Redis error: {s}\n", .{response[1..end]});
                return error.RedisError;
            },
            ':' => {
                // Integer
                const end = std.mem.indexOf(u8, response, "\r\n") orelse response.len;
                return try self.allocator.dupe(u8, response[1..end]);
            },
            '$' => {
                // Bulk string
                if (response.len > 1 and response[1] == '-') {
                    return null; // Null bulk string
                }
                const len_end = std.mem.indexOf(u8, response, "\r\n") orelse return null;
                const len = try std.fmt.parseInt(usize, response[1..len_end], 10);
                const data_start = len_end + 2;
                if (data_start + len <= response.len) {
                    return try self.allocator.dupe(u8, response[data_start .. data_start + len]);
                }
                return null;
            },
            else => return null,
        }
    }

    /// GET command
    pub fn get(self: *Self, key: []const u8) !?[]const u8 {
        const cmd = try self.buildCommand(&.{ "GET", key });
        defer self.allocator.free(cmd);

        const response = try self.sendCommand(cmd);
        return try self.parseResponse(response);
    }

    /// SET command
    pub fn set(self: *Self, key: []const u8, value: []const u8) !void {
        const cmd = try self.buildCommand(&.{ "SET", key, value });
        defer self.allocator.free(cmd);

        const response = try self.sendCommand(cmd);
        defer if (response.len > 0) self.allocator.free(response);
    }

    /// SET with expiration (seconds)
    pub fn setEx(self: *Self, key: []const u8, value: []const u8, seconds: u64) !void {
        const ttl = try std.fmt.allocPrint(self.allocator, "{d}", .{seconds});
        defer self.allocator.free(ttl);

        const cmd = try self.buildCommand(&.{ "SETEX", key, ttl, value });
        defer self.allocator.free(cmd);

        const response = try self.sendCommand(cmd);
        defer if (response.len > 0) self.allocator.free(response);
    }

    /// DEL command
    pub fn del(self: *Self, key: []const u8) !void {
        const cmd = try self.buildCommand(&.{ "DEL", key });
        defer self.allocator.free(cmd);

        const response = try self.sendCommand(cmd);
        defer if (response.len > 0) self.allocator.free(response);
    }

    /// EXISTS command
    pub fn exists(self: *Self, key: []const u8) !bool {
        const cmd = try self.buildCommand(&.{ "EXISTS", key });
        defer self.allocator.free(cmd);

        const response = try self.sendCommand(cmd);
        const result = try self.parseResponse(response);
        defer if (result) |r| self.allocator.free(r);

        if (result) |r| {
            return std.mem.eql(u8, r, "1");
        }
        return false;
    }

    /// EXPIRE command
    pub fn expire(self: *Self, key: []const u8, seconds: u64) !void {
        const ttl = try std.fmt.allocPrint(self.allocator, "{d}", .{seconds});
        defer self.allocator.free(ttl);

        const cmd = try self.buildCommand(&.{ "EXPIRE", key, ttl });
        defer self.allocator.free(cmd);

        const response = try self.sendCommand(cmd);
        defer if (response.len > 0) self.allocator.free(response);
    }

    /// FLUSHDB command
    pub fn flushDb(self: *Self) !void {
        const cmd = try self.buildCommand(&.{"FLUSHDB"});
        defer self.allocator.free(cmd);

        const response = try self.sendCommand(cmd);
        defer if (response.len > 0) self.allocator.free(response);
    }

    /// PING command
    pub fn ping(self: *Self) !bool {
        const cmd = try self.buildCommand(&.{"PING"});
        defer self.allocator.free(cmd);

        const response = try self.sendCommand(cmd);
        const result = try self.parseResponse(response);
        defer if (result) |r| self.allocator.free(r);

        if (result) |r| {
            return std.mem.eql(u8, r, "PONG");
        }
        return false;
    }
};

/// Redis-backed cache implementation
pub const RedisCache = struct {
    client: RedisClient,
    default_ttl: u64 = 300, // 5 minutes

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !RedisCache {
        var client = try RedisClient.init(allocator, host, port);
        try client.connect();

        // Test connection
        if (!try client.ping()) {
            return error.RedisConnectionFailed;
        }

        return RedisCache{
            .client = client,
        };
    }

    pub fn deinit(self: *Self) void {
        self.client.deinit();
    }

    pub fn get(self: *Self, key: []const u8) !?[]const u8 {
        return try self.client.get(key);
    }

    pub fn set(self: *Self, key: []const u8, value: []const u8, ttl: ?u64) !void {
        const seconds = ttl orelse self.default_ttl;
        try self.client.setEx(key, value, seconds);
    }

    pub fn delete(self: *Self, key: []const u8) !void {
        try self.client.del(key);
    }

    pub fn clear(self: *Self) !void {
        try self.client.flushDb();
    }
};
