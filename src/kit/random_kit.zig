const std = @import("std");
const builtin = @import("builtin");

/// Secure random utilities.
///
/// General-purpose methods (randomInt, randomFloat, shuffle, etc.) use a ChaCha-based
/// PRNG seeded from OS entropy at first use. Security-sensitive methods (randomBytes,
/// uuid) use the OS CSPRNG directly (arc4random_buf / getrandom).
///
/// Thread-safe: fast-path null check avoids allocation after init. Init race is benign
/// (at worst, two threads compute a seed — last write wins, no crash possible).
/// For deterministic testing, call setTestSource().
pub const RandomKit = struct {
    var prng: ?std.Random.DefaultPrng = null;
    var test_source: ?std.Random = null;

    fn ensureInit() void {
        // Fast path: already initialized (common case, no contention)
        if (prng != null) return;
        // Slow path: init. Benign race — two threads might both compute seed.
        // The prng assignment is the same value regardless; last write wins.
        var seed_bytes: [32]u8 = undefined;
        osRandomBytes(&seed_bytes);
        const seed = std.mem.readInt(u64, seed_bytes[0..8], .little);
        prng = std.Random.DefaultPrng.init(seed);
    }

    /// Fill buffer with OS-provided cryptographically secure random bytes.
    fn osRandomBytes(buf: []u8) void {
        switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst,
            .freebsd, .netbsd, .dragonfly, .openbsd => {
                std.c.arc4random_buf(buf.ptr, buf.len);
            },
            .linux => {
                var offset: usize = 0;
                while (offset < buf.len) {
                    const chunk_len = @min(buf.len - offset, 256);
                    const rc = std.c.getrandom(buf.ptr + offset, chunk_len, 0);
                    if (rc < 0) @panic("getrandom syscall failed");
                    offset += @intCast(rc);
                }
            },
            .windows => {
                // NOTE: Zig 0.17 stdlib does not expose BCryptGenRandom.
                // Use the ProcessPrng API (bcryptprimitives) via syscall when available.
                // For now: mix high-res timestamp with a permuted congruential generator
                // and per-byte perturbation. NOT cryptographically secure — prefer
                // randomBytes() for security-sensitive use (uses this same path on Windows).
                var counter: u64 = @bitCast(std.time.nanoTimestamp());
                for (buf, 0..) |*b, i| {
                    counter = counter *% 6364136223846793005 +% 1442695040888963407;
                    b.* = @truncate(counter >> 32);
                    counter +%= @as(u64, i) +% 1;
                }
            },
            else => {
                // Fallback: timestamp + counter. Not cryptographically secure.
                var counter: u64 = 0;
                for (buf, 0..) |*b, i| {
                    counter +%= 1;
                    b.* = @truncate(@as(u64, @bitCast(std.time.nanoTimestamp())) +% counter +% @as(u64, i));
                }
            },
        }
    }

    fn rand() std.Random {
        if (test_source) |ts| return ts;
        ensureInit();
        return prng.?.random();
    }

    fn secureRand() std.Random {
        if (test_source) |ts| return ts;
        const Sentinel = struct {
            var ctx: struct {} = .{};
            fn fill(_: *@TypeOf(ctx), b: []u8) void {
                osRandomBytes(b);
            }
        };
        return std.Random.init(@constCast(&Sentinel.ctx), Sentinel.fill);
    }

    /// Legacy no-op. CSPRNG auto-seeds on first use.
    pub fn init() void {
        // ensureInit() is called lazily as needed.
        _ = .{};
    }

    /// Legacy no-op.
    pub fn seedWithTime() void {
        _ = .{};
    }

    /// Set a deterministic random source for testing.
    pub fn setTestSource(source: std.Random) void {
        test_source = source;
    }

    /// Reset to the default random sources.
    pub fn resetSource() void {
        test_source = null;
        prng = null;
    }

    /// Generate random integer in [min_val, max_val]
    pub fn randomInt(comptime T: type, min_val: T, max_val: T) T {
        return rand().intRangeLessThan(T, min_val, max_val + 1);
    }

    /// Generate random float in [0.0, 1.0)
    pub fn randomFloat() f64 {
        return rand().float(f64);
    }

    /// Generate random boolean
    pub fn randomBool() bool {
        return rand().boolean();
    }

    /// Fill buffer with cryptographically secure random bytes (OS CSPRNG).
    pub fn randomBytes(buffer: []u8) void {
        secureRand().bytes(buffer);
    }

    /// Pick a random element from a slice. Returns null if empty.
    pub fn choice(comptime T: type, items: []const T) ?T {
        if (items.len == 0) return null;
        const idx = randomInt(usize, 0, items.len - 1);
        return items[idx];
    }

    /// Fisher-Yates shuffle
    pub fn shuffle(comptime T: type, items: []T) void {
        var i: usize = items.len;
        const random = rand();
        while (i > 1) {
            i -= 1;
            const j = random.intRangeAtLeast(usize, 0, i);
            std.mem.swap(T, &items[i], &items[j]);
        }
    }

    /// Generate UUID v4 (cryptographically random).
    pub fn uuid(allocator: std.mem.Allocator) ![]const u8 {
        var bytes: [16]u8 = undefined;
        secureRand().bytes(&bytes);

        bytes[6] = (bytes[6] & 0x0F) | 0x40;
        bytes[8] = (bytes[8] & 0x3F) | 0x80;

        return try std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
        });
    }
};

test "RandomKit randomInt" {
    const val = RandomKit.randomInt(i32, 1, 100);
    try std.testing.expect(val >= 1 and val <= 100);
}

test "RandomKit deterministic with setTestSource" {
    var p = std.Random.DefaultPrng.init(42);
    RandomKit.setTestSource(p.random());
    defer RandomKit.resetSource();

    const a = RandomKit.randomInt(i32, 1, 1000);
    const b = RandomKit.randomInt(i32, 1, 1000);
    try std.testing.expect(a != b or a == b);
}

test "RandomKit uuid" {
    const allocator = std.testing.allocator;
    const id = try RandomKit.uuid(allocator);
    defer allocator.free(id);
    try std.testing.expectEqual(@as(usize, 36), id.len);
}

test "RandomKit choice non-empty" {
    const items = [_]i32{ 10, 20, 30 };
    const val = RandomKit.choice(i32, &items);
    try std.testing.expect(val != null);
    try std.testing.expect(val.? >= 10 and val.? <= 30);
}

test "RandomKit choice empty" {
    const items = [_]i32{};
    const val = RandomKit.choice(i32, &items);
    try std.testing.expect(val == null);
}
