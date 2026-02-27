const std = @import("std");

/// 文件工具类
pub const FileKit = struct {
    /// 读取整个文件
    pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        return try file.readToEndAlloc(allocator, 100 * 1024 * 1024); // 最大 100MB
    }

    /// 写入文件
    pub fn writeFile(path: []const u8, content: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        try file.writeAll(content);
    }

    /// 追加到文件
    pub fn appendFile(path: []const u8, content: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
        defer file.close();

        try file.seekFromEnd(0);
        try file.writeAll(content);
    }

    /// 复制文件
    pub fn copyFile(src: []const u8, dest: []const u8) !void {
        try std.fs.cwd().copyFile(src, std.fs.cwd(), dest, .{});
    }

    /// 删除文件
    pub fn deleteFile(path: []const u8) !void {
        try std.fs.cwd().deleteFile(path);
    }

    /// 创建目录
    pub fn mkdir(path: []const u8) !void {
        try std.fs.cwd().makePath(path);
    }

    /// 删除目录
    pub fn rmdir(path: []const u8) !void {
        try std.fs.cwd().deleteTree(path);
    }

    /// 列出目录内容
    pub fn listDir(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
        var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        defer dir.close();

        var result = std.ArrayList([]const u8).init(allocator);
        defer result.deinit();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            try result.append(try allocator.dupe(u8, entry.name));
        }

        return result.toOwnedSlice();
    }

    /// 获取文件大小
    pub fn fileSize(path: []const u8) !u64 {
        const stat = try std.fs.cwd().statFile(path);
        return stat.size;
    }
};

test "FileKit read and write" {
    const allocator = std.testing.allocator;

    const test_file = "test_file.txt";
    const content = "Hello, FileKit!";

    // 写入
    try FileKit.writeFile(test_file, content);
    defer FileKit.deleteFile(test_file) catch {};

    // 读取
    const read_content = try FileKit.readFile(allocator, test_file);
    defer allocator.free(read_content);

    try std.testing.expectEqualStrings(content, read_content);
}
