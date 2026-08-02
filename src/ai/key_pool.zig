//! Multi-key pool for high-concurrency LLM access: RPM bucket + inflight gate + cooldown.
//! Used by `AiProvider` when `key_pool != null`. Strategy: least-inflight, then round-robin.

const std = @import("std");
const time_util = @import("time_util.zig");

pub const TokenBucket = struct {
    io: std.Io,
    mutex: std.Io.Mutex,
    tokens: f64,
    max_tokens: f64,
    refill_per_sec: f64,
    last_ms: i64,

    pub fn init(io: std.Io, max_tokens: f64, refill_per_sec: f64) TokenBucket {
        return .{
            .io = io,
            .mutex = .init,
            .tokens = max_tokens,
            .max_tokens = max_tokens,
            .refill_per_sec = refill_per_sec,
            .last_ms = time_util.nowMillis(),
        };
    }

    pub fn tryAcquire(self: *TokenBucket) bool {
        self.mutex.lock(self.io) catch return false;
        defer self.mutex.unlock(self.io);
        const now = time_util.nowMillis();
        const elapsed_ms = @max(now - self.last_ms, 0);
        self.last_ms = now;
        self.tokens = @min(self.max_tokens, self.tokens + @as(f64, @floatFromInt(elapsed_ms)) * self.refill_per_sec / 1000.0);
        if (self.tokens < 1.0) return false;
        self.tokens -= 1.0;
        return true;
    }
};

pub const KeyPoolConfig = struct {
    /// API keys (borrowed; pool does not free them).
    keys: []const []const u8,
    /// Optional short ids for metrics (same length as keys, or empty → auto `k0`..).
    ids: []const []const u8 = &.{},
    /// Per-key requests per minute (token bucket capacity = rpm, refill = rpm/60).
    rpm_per_key: u32 = 60,
    /// Max concurrent in-flight requests per key.
    max_inflight_per_key: u32 = 8,
    /// Cooldown after HTTP 429 (ms).
    cooldown_ms_429: i64 = 2_000,
    /// Cooldown after 401/403 (ms).
    cooldown_ms_auth: i64 = 60_000,
};

pub const KeySlot = struct {
    id: []const u8,
    key: []const u8,
    bucket: TokenBucket,
    cooldown_until_ms: i64 = 0,
    inflight: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    max_inflight: u32,
};

pub const Acquired = struct {
    index: usize,
    key: []const u8,
    id: []const u8,
};

pub const KeyPoolMetrics = struct {
    acquires: std.atomic.Value(usize) = .init(0),
    rotations: std.atomic.Value(usize) = .init(0),
    cooldowns: std.atomic.Value(usize) = .init(0),
    exhausted: std.atomic.Value(usize) = .init(0),

    pub const Snapshot = struct {
        acquires: usize,
        rotations: usize,
        cooldowns: usize,
        exhausted: usize,
    };

    pub fn snapshot(self: *const KeyPoolMetrics) Snapshot {
        return .{
            .acquires = self.acquires.load(.monotonic),
            .rotations = self.rotations.load(.monotonic),
            .cooldowns = self.cooldowns.load(.monotonic),
            .exhausted = self.exhausted.load(.monotonic),
        };
    }
};

/// Optional cross-process cooldown sync (Memory default; Redis adapter can implement later).
pub const CooldownStore = struct {
    ptr: *anyopaque,
    getUntilFn: *const fn (ptr: *anyopaque, key_id: []const u8) i64,
    setUntilFn: *const fn (ptr: *anyopaque, key_id: []const u8, until_ms: i64) void,

    pub fn getUntil(self: CooldownStore, key_id: []const u8) i64 {
        return self.getUntilFn(self.ptr, key_id);
    }
    pub fn setUntil(self: CooldownStore, key_id: []const u8, until_ms: i64) void {
        self.setUntilFn(self.ptr, key_id, until_ms);
    }
};

pub const MemoryCooldownStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    map: std.StringHashMap(i64),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) MemoryCooldownStore {
        return .{
            .allocator = allocator,
            .io = io,
            .mutex = .init,
            .map = std.StringHashMap(i64).init(allocator),
        };
    }

    pub fn deinit(self: *MemoryCooldownStore) void {
        var it = self.map.iterator();
        while (it.next()) |e| self.allocator.free(e.key_ptr.*);
        self.map.deinit();
        self.* = undefined;
    }

    pub fn store(self: *MemoryCooldownStore) CooldownStore {
        return .{
            .ptr = self,
            .getUntilFn = getUntil,
            .setUntilFn = setUntil,
        };
    }

    fn getUntil(ptr: *anyopaque, key_id: []const u8) i64 {
        const self: *MemoryCooldownStore = @ptrCast(@alignCast(ptr));
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        return self.map.get(key_id) orelse 0;
    }

    fn setUntil(ptr: *anyopaque, key_id: []const u8, until_ms: i64) void {
        const self: *MemoryCooldownStore = @ptrCast(@alignCast(ptr));
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        if (self.map.getPtr(key_id)) |v| {
            v.* = @max(v.*, until_ms);
            return;
        }
        const owned = self.allocator.dupe(u8, key_id) catch return;
        self.map.put(owned, until_ms) catch {
            self.allocator.free(owned);
        };
    }
};

pub const KeyPool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    slots: []KeySlot,
    /// Owned short ids when config.ids is empty.
    owned_ids: [][]u8 = &.{},
    rr: usize = 0,
    metrics: KeyPoolMetrics = .{},
    cooldown_ms_429: i64,
    cooldown_ms_auth: i64,
    /// Optional shared cooldown backend (e.g. Memory now; Redis later).
    cooldown_store: ?CooldownStore = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cfg: KeyPoolConfig) !KeyPool {
        if (cfg.keys.len == 0) return error.EmptyKeyPool;

        var owned_ids: [][]u8 = &.{};
        errdefer {
            for (owned_ids) |s| allocator.free(s);
            if (owned_ids.len > 0) allocator.free(owned_ids);
        }

        if (cfg.ids.len == 0) {
            owned_ids = try allocator.alloc([]u8, cfg.keys.len);
            @memset(owned_ids, &.{});
            for (owned_ids, 0..) |*slot, i| {
                slot.* = try std.fmt.allocPrint(allocator, "k{d}", .{i});
            }
        } else if (cfg.ids.len != cfg.keys.len) {
            return error.IdCountMismatch;
        }

        const slots = try allocator.alloc(KeySlot, cfg.keys.len);
        errdefer allocator.free(slots);

        const rpm: f64 = @floatFromInt(@max(cfg.rpm_per_key, 1));
        const refill = rpm / 60.0;
        for (slots, 0..) |*slot, i| {
            const id = if (owned_ids.len > 0) owned_ids[i] else cfg.ids[i];
            slot.* = .{
                .id = id,
                .key = cfg.keys[i],
                .bucket = TokenBucket.init(io, rpm, refill),
                .max_inflight = @max(cfg.max_inflight_per_key, 1),
            };
        }

        return .{
            .allocator = allocator,
            .io = io,
            .mutex = .init,
            .slots = slots,
            .owned_ids = owned_ids,
            .cooldown_ms_429 = cfg.cooldown_ms_429,
            .cooldown_ms_auth = cfg.cooldown_ms_auth,
        };
    }

    pub fn deinit(self: *KeyPool) void {
        for (self.owned_ids) |s| self.allocator.free(s);
        if (self.owned_ids.len > 0) self.allocator.free(self.owned_ids);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Pick a usable slot (not cooling down, under inflight cap, RPM available).
    /// Strategy: least-inflight; ties broken by round-robin distance from `rr`.
    pub fn acquire(self: *KeyPool) !Acquired {
        self.mutex.lock(self.io) catch return error.AllKeysExhausted;
        defer self.mutex.unlock(self.io);

        const now = time_util.nowMillis();
        const n = self.slots.len;
        var best_i: ?usize = null;
        var best_inflight: u32 = std.math.maxInt(u32);
        var best_rr_dist: usize = n;

        var tried: usize = 0;
        while (tried < n) : (tried += 1) {
            const i = (self.rr + tried) % n;
            const slot = &self.slots[i];
            var cool_until = slot.cooldown_until_ms;
            if (self.cooldown_store) |store| {
                cool_until = @max(cool_until, store.getUntil(slot.id));
                slot.cooldown_until_ms = cool_until;
            }
            if (cool_until > now) continue;
            const inflight = slot.inflight.load(.monotonic);
            if (inflight >= slot.max_inflight) continue;
            if (!peekBucket(&slot.bucket)) continue;
            if (inflight < best_inflight or (inflight == best_inflight and tried < best_rr_dist)) {
                best_inflight = inflight;
                best_rr_dist = tried;
                best_i = i;
            }
        }

        const idx = best_i orelse {
            _ = self.metrics.exhausted.fetchAdd(1, .monotonic);
            return error.AllKeysExhausted;
        };
        const slot = &self.slots[idx];
        if (!slot.bucket.tryAcquire()) {
            _ = self.metrics.exhausted.fetchAdd(1, .monotonic);
            return error.AllKeysExhausted;
        }
        _ = slot.inflight.fetchAdd(1, .monotonic);
        self.rr = (idx + 1) % n;
        _ = self.metrics.acquires.fetchAdd(1, .monotonic);
        return .{ .index = idx, .key = slot.key, .id = slot.id };
    }

    pub fn release(self: *KeyPool, a: Acquired) void {
        if (a.index >= self.slots.len) return;
        const slot = &self.slots[a.index];
        var cur = slot.inflight.load(.monotonic);
        while (cur > 0) {
            if (slot.inflight.cmpxchgWeak(cur, cur - 1, .monotonic, .monotonic)) |actual| {
                cur = actual;
            } else break;
        }
    }

    pub fn markCooldown(self: *KeyPool, a: Acquired, ms: i64) void {
        if (a.index >= self.slots.len) return;
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        const until = time_util.nowMillis() + ms;
        self.slots[a.index].cooldown_until_ms = @max(self.slots[a.index].cooldown_until_ms, until);
        if (self.cooldown_store) |store| {
            store.setUntil(self.slots[a.index].id, until);
        }
        _ = self.metrics.cooldowns.fetchAdd(1, .monotonic);
    }

    pub fn markRateLimited(self: *KeyPool, a: Acquired) void {
        self.markCooldown(a, self.cooldown_ms_429);
        _ = self.metrics.rotations.fetchAdd(1, .monotonic);
    }

    pub fn markBad(self: *KeyPool, a: Acquired) void {
        self.markCooldown(a, self.cooldown_ms_auth);
        _ = self.metrics.rotations.fetchAdd(1, .monotonic);
    }

    pub fn slotCount(self: *const KeyPool) usize {
        return self.slots.len;
    }
};

fn peekBucket(b: *TokenBucket) bool {
    b.mutex.lock(b.io) catch return false;
    defer b.mutex.unlock(b.io);
    const now = time_util.nowMillis();
    const elapsed_ms = @max(now - b.last_ms, 0);
    const tokens = @min(b.max_tokens, b.tokens + @as(f64, @floatFromInt(elapsed_ms)) * b.refill_per_sec / 1000.0);
    return tokens >= 1.0;
}

test "KeyPool rotates across keys" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const keys = [_][]const u8{ "sk-a", "sk-b", "sk-c" };
    var pool = try KeyPool.init(allocator, io, .{
        .keys = &keys,
        .rpm_per_key = 10_000,
        .max_inflight_per_key = 32,
    });
    defer pool.deinit();

    var seen: [3]bool = .{ false, false, false };
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const a = try pool.acquire();
        seen[a.index] = true;
        pool.release(a);
    }
    try std.testing.expect(seen[0] and seen[1] and seen[2]);
}

test "KeyPool skips cooldown slots" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const keys = [_][]const u8{ "sk-a", "sk-b" };
    var pool = try KeyPool.init(allocator, io, .{
        .keys = &keys,
        .rpm_per_key = 10_000,
        .max_inflight_per_key = 32,
        .cooldown_ms_429 = 60_000,
    });
    defer pool.deinit();

    const a0 = try pool.acquire();
    pool.markRateLimited(a0);
    pool.release(a0);

    const a1 = try pool.acquire();
    try std.testing.expect(a1.index != a0.index);
    pool.release(a1);
}

test "KeyPool exhausts when all cooling down" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const keys = [_][]const u8{"sk-only"};
    var pool = try KeyPool.init(allocator, io, .{
        .keys = &keys,
        .rpm_per_key = 10_000,
        .max_inflight_per_key = 1,
        .cooldown_ms_429 = 60_000,
    });
    defer pool.deinit();

    const a = try pool.acquire();
    pool.markRateLimited(a);
    pool.release(a);
    try std.testing.expectError(error.AllKeysExhausted, pool.acquire());
}

test "KeyPool respects max_inflight" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const keys = [_][]const u8{"sk-x"};
    var pool = try KeyPool.init(allocator, io, .{
        .keys = &keys,
        .rpm_per_key = 10_000,
        .max_inflight_per_key = 1,
    });
    defer pool.deinit();

    const a = try pool.acquire();
    try std.testing.expectError(error.AllKeysExhausted, pool.acquire());
    pool.release(a);
    const b = try pool.acquire();
    pool.release(b);
}

test "MemoryCooldownStore syncs across pools" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var mem = MemoryCooldownStore.init(allocator, io);
    defer mem.deinit();
    const shared = mem.store();

    const keys = [_][]const u8{"sk-a"};
    var pool_a = try KeyPool.init(allocator, io, .{
        .keys = &keys,
        .ids = &.{"k0"},
        .rpm_per_key = 10_000,
        .max_inflight_per_key = 4,
        .cooldown_ms_429 = 60_000,
    });
    defer pool_a.deinit();
    pool_a.cooldown_store = shared;

    var pool_b = try KeyPool.init(allocator, io, .{
        .keys = &keys,
        .ids = &.{"k0"},
        .rpm_per_key = 10_000,
        .max_inflight_per_key = 4,
        .cooldown_ms_429 = 60_000,
    });
    defer pool_b.deinit();
    pool_b.cooldown_store = shared;

    const a = try pool_a.acquire();
    pool_a.markRateLimited(a);
    pool_a.release(a);

    try std.testing.expectError(error.AllKeysExhausted, pool_b.acquire());
    const snap = pool_a.metrics.snapshot();
    try std.testing.expect(snap.cooldowns >= 1);
}
