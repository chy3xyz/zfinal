const std = @import("std");
const RandomKit = @import("random_kit.zig").RandomKit;

/// 哈希工具类（参考 JFinal HashKit）
pub const HashKit = struct {
    /// MD5 哈希
    pub fn md5(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
        var hash: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(data, &hash, .{});

        return try hexEncode(allocator, &hash);
    }

    /// SHA1 哈希
    pub fn sha1(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
        var hash: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(data, &hash, .{});

        return try hexEncode(allocator, &hash);
    }

    /// SHA256 哈希
    pub fn sha256(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});

        return try hexEncode(allocator, &hash);
    }

    /// SHA512 哈希
    pub fn sha512(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
        var hash: [64]u8 = undefined;
        std.crypto.hash.sha2.Sha512.hash(data, &hash, .{});

        return try hexEncode(allocator, &hash);
    }

    /// Base64 编码
    pub fn base64Encode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
        const encoder = std.base64.standard.Encoder;
        const encoded_len = encoder.calcSize(data.len);

        const result = try allocator.alloc(u8, encoded_len);
        _ = encoder.encode(result, data);

        return result;
    }

    /// Base64 解码
    pub fn base64Decode(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
        const decoder = std.base64.standard.Decoder;
        const decoded_len = try decoder.calcSizeForSlice(encoded);

        const result = try allocator.alloc(u8, decoded_len);
        try decoder.decode(result, encoded);

        return result;
    }

    /// 生成随机字符串
    pub fn generateRandomString(allocator: std.mem.Allocator, length: usize) ![]const u8 {
        const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
        var result = try allocator.alloc(u8, length);
        errdefer allocator.free(result);
        // Secure CSPRNG via RandomKit; rejection sampling avoids modulo bias.
        const limit: u8 = 248; // 62 * 4
        var i: usize = 0;
        while (i < length) {
            var chunk: [32]u8 = undefined;
            RandomKit.randomBytes(&chunk);
            for (chunk) |b| {
                if (b >= limit) continue;
                result[i] = chars[b % chars.len];
                i += 1;
                if (i == length) break;
            }
        }
        return result;
    }

    /// 十六进制编码
    fn hexEncode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
        const hex_chars = "0123456789abcdef";
        var result = try allocator.alloc(u8, data.len * 2);

        for (data, 0..) |byte, i| {
            result[i * 2] = hex_chars[byte >> 4];
            result[i * 2 + 1] = hex_chars[byte & 0x0F];
        }

        return result;
    }
};

test "HashKit md5" {
    const allocator = std.testing.allocator;

    const hash = try HashKit.md5(allocator, "hello");
    defer allocator.free(hash);

    try std.testing.expectEqualStrings("5d41402abc4b2a76b9719d911017c592", hash);
}

test "HashKit base64" {
    const allocator = std.testing.allocator;

    const encoded = try HashKit.base64Encode(allocator, "hello");
    defer allocator.free(encoded);

    const decoded = try HashKit.base64Decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings("hello", decoded);
}
