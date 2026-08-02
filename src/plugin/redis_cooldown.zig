//! Redis-backed `CooldownStore` for cross-process KeyPool cooldown sync.
//! Keys: `{prefix}{key_id}` → decimal `until_ms`; TTL ≈ remaining cooldown.

const std = @import("std");
const RedisClient = @import("redis.zig").RedisClient;
const key_pool = @import("../ai/key_pool.zig");
const time_util = @import("../ai/time_util.zig");

pub const CooldownStore = key_pool.CooldownStore;

pub const RedisCooldownStore = struct {
    client: *RedisClient,
    /// Borrowed prefix, e.g. `zfinal:ai:cd:`.
    key_prefix: []const u8 = "zfinal:ai:cd:",

    pub fn init(client: *RedisClient, key_prefix: []const u8) RedisCooldownStore {
        return .{
            .client = client,
            .key_prefix = if (key_prefix.len > 0) key_prefix else "zfinal:ai:cd:",
        };
    }

    pub fn store(self: *RedisCooldownStore) CooldownStore {
        return .{
            .ptr = self,
            .getUntilFn = getUntil,
            .setUntilFn = setUntil,
        };
    }

    fn makeKey(self: *RedisCooldownStore, buf: []u8, key_id: []const u8) ![]const u8 {
        return try std.fmt.bufPrint(buf, "{s}{s}", .{ self.key_prefix, key_id });
    }

    fn getUntil(ptr: *anyopaque, key_id: []const u8) i64 {
        const self: *RedisCooldownStore = @ptrCast(@alignCast(ptr));
        var key_buf: [256]u8 = undefined;
        const key = self.makeKey(&key_buf, key_id) catch return 0;
        const raw = self.client.get(key) catch return 0;
        const val = raw orelse return 0;
        defer self.client.allocator.free(val);
        return std.fmt.parseInt(i64, val, 10) catch 0;
    }

    fn setUntil(ptr: *anyopaque, key_id: []const u8, until_ms: i64) void {
        const self: *RedisCooldownStore = @ptrCast(@alignCast(ptr));
        var key_buf: [256]u8 = undefined;
        const key = self.makeKey(&key_buf, key_id) catch return;
        var val_buf: [32]u8 = undefined;
        const val = std.fmt.bufPrint(&val_buf, "{d}", .{until_ms}) catch return;

        const now = time_util.nowMillis();
        const remain_ms = until_ms - now;
        if (remain_ms <= 0) {
            self.client.del(key) catch {};
            return;
        }
        // SETEX needs seconds; round up so key outlives the cooldown.
        const ttl_sec: u64 = @intCast(@divTrunc(remain_ms + 999, 1000));
        self.client.setEx(key, val, @max(ttl_sec, 1)) catch {
            self.client.set(key, val) catch {};
        };
    }
};

test "RedisCooldownStore store() vtable wiring" {
    var dummy_client: RedisClient = undefined;
    var rcs = RedisCooldownStore.init(&dummy_client, "test:");
    const s = rcs.store();
    try std.testing.expect(@intFromPtr(s.ptr) == @intFromPtr(&rcs));
    // Call sites must be non-null function pointers.
    try std.testing.expect(@intFromPtr(s.getUntilFn) != 0);
    try std.testing.expect(@intFromPtr(s.setUntilFn) != 0);
}
