const std = @import("std");

/// 路径工具类（参考 JFinal PathKit）
pub const PathKit = struct {
    /// 获取文件扩展名
    pub fn getExt(path: []const u8) ?[]const u8 {
        if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot_pos| {
            return path[dot_pos + 1 ..];
        }
        return null;
    }

    /// 获取文件名（不含扩展名）
    pub fn getBaseName(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        const basename = std.fs.path.basename(path);

        if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot_pos| {
            return try allocator.dupe(u8, basename[0..dot_pos]);
        }

        return try allocator.dupe(u8, basename);
    }

    /// 获取目录名
    pub fn getDirName(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        return try allocator.dupe(u8, std.fs.path.dirname(path) orelse ".");
    }

    /// 连接路径
    pub fn join(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
        return try std.fs.path.join(allocator, parts);
    }

    /// 规范化路径
    pub fn normalize(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        return try std.fs.path.resolve(allocator, &[_][]const u8{path});
    }

    /// 检查文件是否存在
    pub fn exists(path: []const u8) bool {
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }

    /// 检查是否是目录
    pub fn isDir(path: []const u8) bool {
        const stat = std.fs.cwd().statFile(path) catch return false;
        return stat.kind == .directory;
    }

    /// 检查是否是文件
    pub fn isFile(path: []const u8) bool {
        const stat = std.fs.cwd().statFile(path) catch return false;
        return stat.kind == .file;
    }
};

test "PathKit getExt" {
    try std.testing.expectEqualStrings("txt", PathKit.getExt("file.txt").?);
    try std.testing.expectEqualStrings("zig", PathKit.getExt("path/to/file.zig").?);
    try std.testing.expect(PathKit.getExt("noext") == null);
}

test "PathKit join" {
    const allocator = std.testing.allocator;

    const path = try PathKit.join(allocator, &[_][]const u8{ "path", "to", "file.txt" });
    defer allocator.free(path);

    try std.testing.expect(std.mem.indexOf(u8, path, "file.txt") != null);
}
