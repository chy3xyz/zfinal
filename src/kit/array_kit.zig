const std = @import("std");

/// 数组工具类
pub const ArrayKit = struct {
    /// 检查数组是否包含元素
    pub fn contains(comptime T: type, array: []const T, item: T) bool {
        for (array) |elem| {
            if (std.meta.eql(elem, item)) return true;
        }
        return false;
    }

    /// 查找元素索引
    pub fn indexOf(comptime T: type, array: []const T, item: T) ?usize {
        for (array, 0..) |elem, i| {
            if (std.meta.eql(elem, item)) return i;
        }
        return null;
    }

    /// 反转数组
    pub fn reverse(comptime T: type, array: []T) void {
        var i: usize = 0;
        var j: usize = array.len - 1;
        while (i < j) {
            std.mem.swap(T, &array[i], &array[j]);
            i += 1;
            j -= 1;
        }
    }

    /// 去重
    pub fn unique(comptime T: type, allocator: std.mem.Allocator, array: []const T) ![]T {
        var seen = std.AutoHashMap(T, void).init(allocator);
        defer seen.deinit();

        var result = std.ArrayList(T).init(allocator);
        defer result.deinit();

        for (array) |item| {
            if (!seen.contains(item)) {
                try seen.put(item, {});
                try result.append(item);
            }
        }

        return result.toOwnedSlice();
    }

    /// 过滤数组
    pub fn filter(comptime T: type, allocator: std.mem.Allocator, array: []const T, predicate: *const fn (T) bool) ![]T {
        var result = std.ArrayList(T).init(allocator);
        defer result.deinit();

        for (array) |item| {
            if (predicate(item)) {
                try result.append(item);
            }
        }

        return result.toOwnedSlice();
    }

    /// 映射数组
    pub fn map(comptime T: type, comptime R: type, allocator: std.mem.Allocator, array: []const T, mapper: *const fn (T) R) ![]R {
        var result = try allocator.alloc(R, array.len);

        for (array, 0..) |item, i| {
            result[i] = mapper(item);
        }

        return result;
    }

    /// 求和
    pub fn sum(comptime T: type, array: []const T) T {
        var total: T = 0;
        for (array) |item| {
            total += item;
        }
        return total;
    }

    /// 最大值
    pub fn max(comptime T: type, array: []const T) ?T {
        if (array.len == 0) return null;
        var maximum = array[0];
        for (array[1..]) |item| {
            if (item > maximum) maximum = item;
        }
        return maximum;
    }

    /// 最小值
    pub fn min(comptime T: type, array: []const T) ?T {
        if (array.len == 0) return null;
        var minimum = array[0];
        for (array[1..]) |item| {
            if (item < minimum) minimum = item;
        }
        return minimum;
    }
};

test "ArrayKit contains" {
    const array = [_]i32{ 1, 2, 3, 4, 5 };
    try std.testing.expect(ArrayKit.contains(i32, &array, 3));
    try std.testing.expect(!ArrayKit.contains(i32, &array, 10));
}

test "ArrayKit sum" {
    const array = [_]i32{ 1, 2, 3, 4, 5 };
    try std.testing.expectEqual(@as(i32, 15), ArrayKit.sum(i32, &array));
}
