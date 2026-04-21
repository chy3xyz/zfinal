const std = @import("std");

/// 随机工具类
pub const RandomKit = struct {
    var prng: std.Random.DefaultPrng = undefined;

    /// Initialize the random generator (call once at startup)
    pub fn init() void {
        prng = std.Random.DefaultPrng.init(0);
    }

    /// Seed with current timestamp
    pub fn seedWithTime() void {
prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.timestamp())));
    }

    /// Get the random generator
    fn rand() std.Random {
        return prng.random();
    }

    /// 生成随机整数 [min_val, max_val]
    pub fn randomInt(comptime T: type, min_val: T, max_val: T) T {
        const random = rand();
        return random.intRangeLessThan(T, min_val, max_val + 1);
    }

    /// 生成随机浮点数 [0.0, 1.0)
    pub fn randomFloat() f64 {
        return rand().float(f64);
    }

    /// 生成随机布尔值
    pub fn randomBool() bool {
        return rand().boolean();
    }

    /// 生成随机字节数组
    pub fn randomBytes(buffer: []u8) void {
        rand().bytes(buffer);
    }

    /// 从数组中随机选择一个元素
    pub fn choice(comptime T: type, items: []const T) T {
        const idx = randomInt(usize, 0, items.len - 1);
        return items[idx];
    }

    /// 打乱数组 (Fisher-Yates shuffle)
    pub fn shuffle(comptime T: type, items: []T) void {
        var i: usize = items.len;
        const random = rand();
        while (i > 1) {
            i -= 1;
            const j = random.intRangeAtLeast(usize, 0, i);
            std.mem.swap(T, &items[i], &items[j]);
        }
    }

    /// 生成 UUID v4
    pub fn uuid(allocator: std.mem.Allocator) ![]const u8 {
        var bytes: [16]u8 = undefined;
        rand().bytes(&bytes);

        // 设置版本和变体位 (UUID v4)
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
    RandomKit.init();
    const val = RandomKit.randomInt(i32, 1, 100);
    try std.testing.expect(val >= 1 and val <= 100);
}

test "RandomKit uuid" {
    RandomKit.init();
    const allocator = std.testing.allocator;

    const id = try RandomKit.uuid(allocator);
    defer allocator.free(id);

    try std.testing.expectEqual(@as(usize, 36), id.len); // UUID format: 8-4-4-4-12
}