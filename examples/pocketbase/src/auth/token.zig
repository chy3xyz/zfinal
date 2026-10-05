const std = @import("std");
const zfinal = @import("zfinal");

/// API Token for authentication
pub const Token = struct {
    token: []const u8,
    user_id: ?[]const u8 = null,
    expires_at: ?i64 = null,
};

/// Generate a random token
pub fn generateToken(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    var random_bytes: [32]u8 = undefined;
    io.random(&random_bytes);

    // Convert to hex string
    const hex_bytes = std.fmt.bytesToHex(&random_bytes, .lower);
    const token = try allocator.alloc(u8, hex_bytes.len);
    @memcpy(token, &hex_bytes);

    return token;
}

/// Validate token against database
pub fn validateToken(token: []const u8, db: *zfinal.DB, allocator: std.mem.Allocator, io: std.Io) !bool {
    _ = allocator; // parameterized query needs no scratch allocation
    const timestamp = std.Io.Timestamp.now(io, .real).toSeconds();
    var rs = try db.queryParams("SELECT COUNT(*) as count FROM _api_tokens WHERE token = ? AND (expires_at IS NULL OR expires_at > ?)", &.{
        .{ .text = token },
        .{ .int = timestamp },
    });
    defer rs.deinit();

    if (rs.next()) {
        const row = rs.getCurrentRowMap().?;
        if (row.get("count")) |count_str| {
            const count = try std.fmt.parseInt(i64, count_str, 10);
            return count > 0;
        }
    }

    return false;
}

/// Get user ID for a token
pub fn getTokenUser(token: []const u8, db: *zfinal.DB, allocator: std.mem.Allocator, io: std.Io) !?[]const u8 {
    const timestamp = std.Io.Timestamp.now(io, .real).toSeconds();
    var rs = try db.queryParams("SELECT user_id FROM _api_tokens WHERE token = ? AND (expires_at IS NULL OR expires_at > ?) LIMIT 1", &.{
        .{ .text = token },
        .{ .int = timestamp },
    });
    defer rs.deinit();

    if (rs.next()) {
        const row = rs.getCurrentRowMap().?;
        if (row.get("user_id")) |user_id| {
            return try allocator.dupe(u8, user_id);
        }
    }

    return null;
}

/// Create a new API token
pub fn createToken(user_id: ?[]const u8, expires_at: ?i64, db: *zfinal.DB, allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const token = try generateToken(allocator, io);

    if (user_id) |uid| {
        try db.execParams("INSERT INTO _api_tokens (token, user_id, expires_at) VALUES (?, ?, ?)", &.{
            .{ .text = token },
            .{ .text = uid },
            .{ .int = expires_at orelse 0 },
        });
    } else {
        try db.execParams("INSERT INTO _api_tokens (token, expires_at) VALUES (?, ?)", &.{
            .{ .text = token },
            .{ .int = expires_at orelse 0 },
        });
    }

    return token;
}
