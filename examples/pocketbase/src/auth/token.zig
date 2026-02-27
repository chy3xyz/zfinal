const std = @import("std");
const zfinal = @import("zfinal");

/// API Token for authentication
pub const Token = struct {
    token: []const u8,
    user_id: ?[]const u8 = null,
    expires_at: ?i64 = null,
};

/// Generate a random token
pub fn generateToken(allocator: std.mem.Allocator) ![]const u8 {
    var random_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    // Convert to hex string
    const token = try allocator.alloc(u8, 64);
    _ = try std.fmt.bufPrint(token, "{s}", .{std.fmt.fmtSliceHexLower(&random_bytes)});

    return token;
}

/// Validate token against database
pub fn validateToken(token: []const u8, db: *zfinal.DB, allocator: std.mem.Allocator) !bool {
    const timestamp = std.time.timestamp();
    const sql = try std.fmt.allocPrintZ(
        allocator,
        "SELECT COUNT(*) as count FROM _api_tokens WHERE token = '{s}' AND (expires_at IS NULL OR expires_at > {d})",
        .{ token, timestamp },
    );
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
pub fn getTokenUser(token: []const u8, db: *zfinal.DB, allocator: std.mem.Allocator) !?[]const u8 {
    const timestamp = std.time.timestamp();
    const sql = try std.fmt.allocPrintZ(
        allocator,
        "SELECT user_id FROM _api_tokens WHERE token = '{s}' AND (expires_at IS NULL OR expires_at > {d}) LIMIT 1",
        .{ token, timestamp },
    );
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
pub fn createToken(user_id: ?[]const u8, expires_at: ?i64, db: *zfinal.DB, allocator: std.mem.Allocator) ![]const u8 {
    const token = try generateToken(allocator);

    const sql = if (user_id != null) blk: {
        const uid = user_id.?;
        const exp = expires_at orelse 0;
        break :blk try std.fmt.allocPrintZ(
            allocator,
            "INSERT INTO _api_tokens (token, user_id, expires_at) VALUES ('{s}', '{s}', {d})",
            .{ token, uid, exp },
        );
    } else blk: {
        const exp = expires_at orelse 0;
        break :blk try std.fmt.allocPrintZ(
            allocator,
            "INSERT INTO _api_tokens (token, expires_at) VALUES ('{s}', {d})",
            .{ token, exp },
        );
    };
    defer allocator.free(sql);

    try db.exec(sql);

    return token;
}
