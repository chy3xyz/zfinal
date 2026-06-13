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
    const timestamp = std.Io.Timestamp.now(io, .real).toSeconds();
    const sql = try std.fmt.allocPrintSentinel(allocator, "SELECT COUNT(*) as count FROM _api_tokens WHERE token = '{s}' AND (expires_at IS NULL OR expires_at > {d})", .{ token, timestamp }, 0);

    defer allocator.free(sql);

    var rs = try db.query(sql);
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
    const sql = try std.fmt.allocPrintSentinel(allocator, "SELECT user_id FROM _api_tokens WHERE token = '{s}' AND (expires_at IS NULL OR expires_at > {d}) LIMIT 1", .{ token, timestamp }, 0);

    defer allocator.free(sql);

    var rs = try db.query(sql);
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

    const sql = if (user_id != null) blk: {
        const uid = user_id.?;
        const exp = expires_at orelse 0;
        break :blk try std.fmt.allocPrintSentinel(
            allocator,
            "INSERT INTO _api_tokens (token, user_id, expires_at) VALUES ('{s}', '{s}', {d})",
            .{ token, uid, exp },
            0,
        );
    } else blk: {
        const exp = expires_at orelse 0;
        break :blk try std.fmt.allocPrintSentinel(
            allocator,
            "INSERT INTO _api_tokens (token, expires_at) VALUES ('{s}', {d})",
            .{ token, exp },
            0,
        );
    };
    defer allocator.free(sql);

    try db.exec(sql);

    return token;
}
