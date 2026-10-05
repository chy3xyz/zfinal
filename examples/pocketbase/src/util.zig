const std = @import("std");

/// Strict SQL identifier whitelist: 1..64 chars, [A-Za-z_][A-Za-z0-9_]*.
///
/// Dynamic table/column names cannot be bound as query parameters, so they must
/// be validated before interpolation. This is the only place the example allows
/// caller-controlled identifiers into SQL text.
pub fn isValidIdentifier(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    const first = name[0];
    if (!(isAlpha(first) or first == '_')) return false;
    for (name[1..]) |c| {
        if (!(isAlnum(c) or c == '_')) return false;
    }
    return true;
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isAlnum(c: u8) bool {
    return isAlpha(c) or (c >= '0' and c <= '9');
}

test "isValidIdentifier" {
    try std.testing.expect(isValidIdentifier("posts"));
    try std.testing.expect(isValidIdentifier("_admins"));
    try std.testing.expect(isValidIdentifier("user_2fa"));
    try std.testing.expect(!isValidIdentifier(""));
    try std.testing.expect(!isValidIdentifier("1posts"));
    try std.testing.expect(!isValidIdentifier("a'b"));
    try std.testing.expect(!isValidIdentifier("a;b"));
    try std.testing.expect(!isValidIdentifier("a b"));
}
