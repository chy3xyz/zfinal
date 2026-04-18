const std = @import("std");
const io_instance = @import("../io_instance.zig");

/// 文件工具类
pub const FileKit = struct {
    /// 读取整个文件
    pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        const file = try std.Io.Dir.cwd().openFile(io_instance.io, path, .{});
        defer file.close(io_instance.io);

        const stat = try file.stat(io_instance.io);
        const buf = try allocator.alloc(u8, stat.size);
        var pos: usize = 0;
        while (pos < stat.size) {
            const bytes_read = try file.read(io_instance.io, buf[pos..]);
            pos += bytes_read;
        }
        return buf;
    }

    /// 写入文件
    pub fn writeFile(path: []const u8, content: []const u8) !void {
        const file = try std.Io.Dir.cwd().createFile(io_instance.io, path, .{});
        defer file.close(io_instance.io);

        try file.writeStreamingAll(io_instance.io, content);
    }

    /// 追加到文件
    pub fn appendFile(path: []const u8, content: []const u8) !void {
        const file = try std.Io.Dir.cwd().openFile(io_instance.io, path, .{ .mode = .write_only });
        defer file.close(io_instance.io);

        try file.seekFromEnd(io_instance.io, 0);
        try file.writeStreamingAll(io_instance.io, content);
    }

    /// 复制文件
    pub fn copyFile(src: []const u8, dest: []const u8) !void {
        try std.Io.Dir.cwd().copyFile(io_instance.io, src, std.Io.Dir.cwd(), dest, .{});
    }

    /// 删除文件
    pub fn deleteFile(path: []const u8) !void {
        try std.Io.Dir.cwd().deleteFile(io_instance.io, path);
    }

    /// 创建目录
    pub fn mkdir(path: []const u8) !void {
        try std.Io.Dir.cwd().makePath(io_instance.io, path);
    }

    /// 删除目录
    pub fn rmdir(path: []const u8) !void {
        try std.Io.Dir.cwd().deleteTree(io_instance.io, path);
    }

    /// 列出目录内容
    pub fn listDir(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
        var dir = try std.Io.Dir.cwd().openDir(io_instance.io, path, .{ .iterate = true });
        defer dir.close(io_instance.io);

        var result = std.ArrayList([]const u8).empty;
        defer result.deinit(allocator);

        var it = dir.iterate(io_instance.io);
        while (try it.next()) |entry| {
            try result.append(allocator, try allocator.dupe(u8, entry.name));
        }

        return result.toOwnedSlice(allocator);
    }

    /// 获取文件大小
    pub fn fileSize(path: []const u8) !u64 {
        const stat = try std.Io.Dir.cwd().statFile(io_instance.io, path);
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
