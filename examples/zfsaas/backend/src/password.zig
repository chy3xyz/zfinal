//! Argon2id password helpers (Zig 0.17 `std.crypto.pwhash.argon2`).
const std = @import("std");
const zfinal = @import("zfinal");
const argon2 = std.crypto.pwhash.argon2;

pub fn hash(allocator: std.mem.Allocator, password: []const u8) ![]u8 {
    var out: [256]u8 = undefined;
    const phc = try argon2.strHash(password, .{
        .allocator = allocator,
        .params = argon2.Params.owasp_2id,
        .mode = .argon2id,
    }, &out, zfinal.io_instance.io);
    return try allocator.dupe(u8, phc);
}

pub fn verify(allocator: std.mem.Allocator, password_hash: []const u8, password: []const u8) bool {
    argon2.strVerify(password_hash, password, .{ .allocator = allocator }, zfinal.io_instance.io) catch return false;
    return true;
}

test "password: hash and verify" {
    const a = std.testing.allocator;
    const h = try hash(a, "secret-pass");
    defer a.free(h);
    try std.testing.expect(verify(a, h, "secret-pass"));
    try std.testing.expect(!verify(a, h, "wrong"));
}
