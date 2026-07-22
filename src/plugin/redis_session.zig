//! Redis-backed session store (thin wrapper over RedisClient SETEX/GET/DEL).
//! Production default remains JWT-stateless — see `doc/session.md`.

const std = @import("std");
const RedisClient = @import("redis.zig").RedisClient;

pub const RedisSessionStore = struct {
    client: *RedisClient,
    allocator: std.mem.Allocator,
    key_prefix: []const u8 = "zfinal:sess:",
    ttl_sec: u64 = 3600,

    pub fn init(allocator: std.mem.Allocator, client: *RedisClient) RedisSessionStore {
        return .{ .client = client, .allocator = allocator };
    }

    fn keyOf(self: *RedisSessionStore, session_id: []const u8) ![]u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.key_prefix, session_id });
    }

    /// Persist opaque session blob with TTL. Caller owns `session_id` and `blob`.
    pub fn put(self: *RedisSessionStore, session_id: []const u8, blob: []const u8) !void {
        const key = try self.keyOf(session_id);
        defer self.allocator.free(key);
        try self.client.setEx(key, blob, self.ttl_sec);
    }

    /// Fetch session blob. Caller frees returned slice.
    pub fn get(self: *RedisSessionStore, session_id: []const u8) !?[]const u8 {
        const key = try self.keyOf(session_id);
        defer self.allocator.free(key);
        return try self.client.get(key);
    }

    pub fn remove(self: *RedisSessionStore, session_id: []const u8) !void {
        const key = try self.keyOf(session_id);
        defer self.allocator.free(key);
        try self.client.del(key);
    }
};
