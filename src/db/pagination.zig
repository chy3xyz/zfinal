const std = @import("std");

/// 分页结果
pub fn Page(comptime T: type) type {
    return struct {
        const Self = @This();

        list: []T,
        page_number: usize,
        page_size: usize,
        total_page: usize,
        total_row: usize,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, list: []T, page_number: usize, page_size: usize, total_row: usize) Self {
            const total_page = if (total_row == 0) 0 else (total_row + page_size - 1) / page_size;

            return Self{
                .list = list,
                .page_number = page_number,
                .page_size = page_size,
                .total_page = total_page,
                .total_row = total_row,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.list);
        }

        /// 是否有上一页
        pub fn hasPrevious(self: *const Self) bool {
            return self.page_number > 1;
        }

        /// 是否有下一页
        pub fn hasNext(self: *const Self) bool {
            return self.page_number < self.total_page;
        }

        /// 获取上一页页码
        pub fn previousPage(self: *const Self) ?usize {
            if (self.hasPrevious()) return self.page_number - 1;
            return null;
        }

        /// 获取下一页页码
        pub fn nextPage(self: *const Self) ?usize {
            if (self.hasNext()) return self.page_number + 1;
            return null;
        }
    };
}

/// SQL 分页辅助函数
pub fn buildPaginationSql(
    allocator: std.mem.Allocator,
    base_sql: []const u8,
    page_number: usize,
    page_size: usize,
) ![]const u8 {
    const offset = (page_number - 1) * page_size;
    return try std.fmt.allocPrint(allocator, "{s} LIMIT {d} OFFSET {d}", .{ base_sql, page_size, offset });
}

test "page basic" {
    const allocator = std.testing.allocator;

    const items = try allocator.alloc(i32, 10);
    for (items, 0..) |*item, i| {
        item.* = @intCast(i);
    }

    var page = Page(i32).init(allocator, items, 2, 10, 25);
    defer page.deinit();

    try std.testing.expectEqual(@as(usize, 2), page.page_number);
    try std.testing.expectEqual(@as(usize, 10), page.page_size);
    try std.testing.expectEqual(@as(usize, 3), page.total_page);
    try std.testing.expectEqual(@as(usize, 25), page.total_row);
    try std.testing.expect(page.hasPrevious());
    try std.testing.expect(page.hasNext());
}

test "pagination sql" {
    const allocator = std.testing.allocator;

    const sql = try buildPaginationSql(allocator, "SELECT * FROM users ORDER BY id", 2, 10);
    defer allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT * FROM users ORDER BY id LIMIT 10 OFFSET 10", sql);
}
