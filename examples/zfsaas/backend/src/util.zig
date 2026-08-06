//! Small crypto/id helpers for SaaS Kit.
const std = @import("std");
const zfinal = @import("zfinal");

pub fn nowUnix() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @intCast(ts.sec);
}

pub fn randomHex(allocator: std.mem.Allocator, nbytes: usize) ![]u8 {
    const raw = try allocator.alloc(u8, nbytes);
    defer allocator.free(raw);
    zfinal.RandomKit.randomBytes(raw);
    const out = try allocator.alloc(u8, nbytes * 2);
    const hex = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
    return out;
}

pub fn sha256Hex(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &digest, .{});
    const out = try allocator.alloc(u8, digest.len * 2);
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
    return out;
}

/// HMAC-SHA256 hex (Stripe webhook signature style).
pub fn hmacSha256Hex(allocator: std.mem.Allocator, secret: []const u8, message: []const u8) ![]u8 {
    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, message, secret);
    const out = try allocator.alloc(u8, mac.len * 2);
    const hex = "0123456789abcdef";
    for (mac, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
    return out;
}
