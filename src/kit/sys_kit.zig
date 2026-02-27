const std = @import("std");

const builtin = @import("builtin");

/// 系统工具类
pub const SysKit = struct {
    /// 获取环境变量
    pub fn getEnv(allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
        const value = std.process.getEnvVarOwned(allocator, key) catch |err| {
            if (err == error.EnvironmentVariableNotFound) return null;
            return err;
        };
        return value;
    }

    /// 设置环境变量
    pub fn setEnv(key: []const u8, value: []const u8) !void {
        var key_buf: [256]u8 = undefined;
        var value_buf: [1024]u8 = undefined;

        const key_z = try std.fmt.bufPrintZ(&key_buf, "{s}", .{key});
        const value_z = try std.fmt.bufPrintZ(&value_buf, "{s}", .{value});

        try std.process.putEnv(key_z, value_z);
    }

    /// 获取当前工作目录
    pub fn getCwd(allocator: std.mem.Allocator) ![]const u8 {
        return try std.process.getCwdAlloc(allocator);
    }

    /// 获取主机名
    pub fn getHostname(allocator: std.mem.Allocator) ![]const u8 {
        var buf: [256]u8 = undefined;
        const hostname = try std.posix.gethostname(&buf);
        return try allocator.dupe(u8, hostname);
    }

    /// 获取用户名
    pub fn getUsername(allocator: std.mem.Allocator) !?[]const u8 {
        return try getEnv(allocator, "USER");
    }

    /// 获取系统信息
    pub fn getSystemInfo() SystemInfo {
        return SystemInfo{
            .os = @tagName(builtin.os.tag),
            .arch = @tagName(builtin.cpu.arch),
        };
    }

    pub const SystemInfo = struct {
        os: []const u8,
        arch: []const u8,
    };

    /// 执行命令
    pub fn exec(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
        var child = std.process.Child.init(argv, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        const stdout = try child.stdout.?.readToEndAlloc(allocator, 10 * 1024 * 1024);
        errdefer allocator.free(stdout);

        _ = try child.wait();

        return stdout;
    }
};

test "SysKit getSystemInfo" {
    const info = SysKit.getSystemInfo();
    try std.testing.expect(info.os.len > 0);
    try std.testing.expect(info.arch.len > 0);
}
