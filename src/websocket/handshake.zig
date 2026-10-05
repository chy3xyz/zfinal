//! RFC 6455 handshake helpers (Sec-WebSocket-Accept).
const std = @import("std");

const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Compute `Sec-WebSocket-Accept` from the client `Sec-WebSocket-Key` value.
pub fn acceptKey(client_key: []const u8, out: *[28]u8) []const u8 {
    // Hash incrementally so an arbitrarily long (attacker-controlled)
    // Sec-WebSocket-Key cannot overflow a fixed stack buffer. Previously a key
    // longer than ~220 bytes made bufPrint fail and `catch unreachable`
    // panicked (ReleaseSafe) or was UB (ReleaseFast).
    var hash: [20]u8 = undefined;
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(client_key);
    sha1.update(guid);
    sha1.final(&hash);
    return std.base64.standard.Encoder.encode(out, &hash);
}

/// Build the 101 Switching Protocols response body (caller owns).
pub fn upgradeResponse(allocator: std.mem.Allocator, client_key: []const u8) ![]u8 {
    var accept_buf: [28]u8 = undefined;
    const accept = acceptKey(client_key, &accept_buf);
    return try std.fmt.allocPrint(allocator,
        \\HTTP/1.1 101 Switching Protocols
        \\Upgrade: websocket
        \\Connection: Upgrade
        \\Sec-WebSocket-Accept: {s}
        \\
        \\
    , .{accept});
}

/// Extract `Sec-WebSocket-Key` from a raw HTTP request head (bytes).
pub fn extractClientKey(request_head: []const u8) ?[]const u8 {
    const prefix = "Sec-WebSocket-Key:";
    const start = std.mem.indexOf(u8, request_head, prefix) orelse return null;
    var i = start + prefix.len;
    while (i < request_head.len and (request_head[i] == ' ' or request_head[i] == '\t')) : (i += 1) {}
    var end = i;
    while (end < request_head.len and request_head[end] != '\r' and request_head[end] != '\n') : (end += 1) {}
    if (end == i) return null;
    return request_head[i..end];
}

pub fn isUpgradeRequest(request_head: []const u8) bool {
    return std.mem.indexOf(u8, request_head, "Upgrade: websocket") != null or
        std.mem.indexOf(u8, request_head, "Upgrade: Websocket") != null or
        std.mem.indexOf(u8, request_head, "upgrade: websocket") != null;
}

test "websocket acceptKey matches RFC 6455 example" {
    // RFC 6455 §1.3 / §4.2.2 example
    var out: [28]u8 = undefined;
    const accept = acceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "websocket acceptKey tolerates an oversized client key" {
    // Regression: a Sec-WebSocket-Key longer than the old 256-byte combined
    // buffer used to hit `catch unreachable` (ReleaseSafe panic / ReleaseFast UB).
    var out: [28]u8 = undefined;
    var big: [4096]u8 = undefined;
    @memset(&big, 'A');
    const accept = acceptKey(&big, &out);
    try std.testing.expectEqual(@as(usize, 28), accept.len);
}

test "websocket extractClientKey" {
    const req =
        \\GET /ws HTTP/1.1
        \\Host: localhost
        \\Upgrade: websocket
        \\Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
        \\
        \\
    ;
    try std.testing.expect(isUpgradeRequest(req));
    try std.testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", extractClientKey(req).?);
}
