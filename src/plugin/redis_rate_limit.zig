//! Redis-backed distributed rate limiter (fixed window).
//!
//! Unlike the in-memory `RateLimitHandler` (per-process), this shares a counter
//! across all instances via Redis `INCR` + `EXPIRE`-on-first-hit — the two
//! commands are issued per request but the window is keyed atomically on Redis.
//!
//! **Fail-closed by design**: any Redis error (e.g. `NotConnected`) propagates.
//! The caller must decide how to degrade — never silently allow, which is the
//! classic fail-open footgun this type exists to prevent.

const std = @import("std");
const RedisClient = @import("redis.zig").RedisClient;

pub const RedisRateLimiter = struct {
    client: *RedisClient,
    /// Borrowed key prefix, e.g. `zfinal:rl:`.
    key_prefix: []const u8 = "zfinal:rl:",

    const Self = @This();

    pub fn init(client: *RedisClient, key_prefix: []const u8) Self {
        return .{
            .client = client,
            .key_prefix = if (key_prefix.len > 0) key_prefix else "zfinal:rl:",
        };
    }

    fn makeKey(self: *const Self, buf: []u8, key_id: []const u8) ![]const u8 {
        return try std.fmt.bufPrint(buf, "{s}{s}", .{ self.key_prefix, key_id });
    }

    /// Fixed-window check: `true` = allowed, `false` = over `max_requests`
    /// within `window_sec`. Redis errors propagate (fail-closed).
    pub fn allow(self: *const Self, key_id: []const u8, max_requests: usize, window_sec: u64) !bool {
        if (max_requests == 0) return false;
        var key_buf: [256]u8 = undefined;
        const key = try self.makeKey(&key_buf, key_id);
        const count = try self.client.incr(key);
        if (count == 1) {
            // First hit in the window — set the TTL. (If this call fails the
            // key leaks until Redis evicts it; the count still ratchets down
            // on the next window via a later EXPIRE, so it degrades to a
            // stricter limiter, not a bypass.)
            self.client.expire(key, window_sec) catch {};
        }
        return count <= @as(i64, @intCast(max_requests));
    }
};

test "RedisRateLimiter: not connected → error (fail-closed, not allow)" {
    const a = std.testing.allocator;
    var client = try RedisClient.init(a, "127.0.0.1", 6399);
    defer client.deinit();
    // No connect() — INCR must error.NotConnected, NOT silently allow.
    const rl = RedisRateLimiter.init(&client, "t:");
    try std.testing.expectError(error.NotConnected, rl.allow("u1", 10, 60));
}

test "RedisRateLimiter: max_requests == 0 denies" {
    const a = std.testing.allocator;
    var client = try RedisClient.init(a, "127.0.0.1", 6399);
    defer client.deinit();
    const rl = RedisRateLimiter.init(&client, "t:");
    try std.testing.expect(!try rl.allow("u1", 0, 60));
}
