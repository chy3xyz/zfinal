//! Auth domain: sign-up / sign-in / me / password reset tokens.
const std = @import("std");
const zfinal = @import("zfinal");
const password = @import("../../password.zig");
const util = @import("../../util.zig");
const state = @import("../../state.zig");

pub const UserRow = struct {
    id: i64,
    email: []const u8,
    name: []const u8,
    locale: []const u8,
};

pub const AuthResult = struct {
    token: []const u8,
    refresh_token: ?[]const u8 = null,
    verify_token: ?[]const u8 = null,
    user_id: i64,
    email: []const u8,
    name: []const u8,
    org_id: ?[]const u8,
    role: ?[]const u8,
    email_verified: bool = false,
};

pub const SignUpError = error{
    EmailTaken,
    WeakPassword,
    ValidationError,
    OutOfMemory,
    DbError,
};

fn isWeak(pw: []const u8) bool {
    return pw.len < 8;
}

/// Register user + personal org + admin membership + inactive subscription.
pub fn signUp(
    db: *zfinal.DB,
    allocator: std.mem.Allocator,
    email: []const u8,
    name: []const u8,
    pw: []const u8,
    jwt_secret: []const u8,
    jwt_ttl_sec: i64,
) !AuthResult {
    if (email.len == 0 or name.len == 0) return error.ValidationError;
    if (isWeak(pw)) return error.WeakPassword;

    const hash = try password.hash(allocator, pw);
    defer allocator.free(hash);

    try db.begin();
    errdefer db.rollback() catch {};

    db.execParams(
        "INSERT INTO users (email, name, password_hash) VALUES (?, ?, ?)",
        &.{
            .{ .text = email },
            .{ .text = name },
            .{ .text = hash },
        },
    ) catch return error.EmailTaken;

    const user_id = try db.lastInsertId();
    const org_id = try util.randomHex(allocator, 12);
    errdefer allocator.free(org_id);

    const org_name = try std.fmt.allocPrint(allocator, "{s}'s Org", .{name});
    defer allocator.free(org_name);

    try db.execParams(
        "INSERT INTO organizations (id, name) VALUES (?, ?)",
        &.{ .{ .text = org_id }, .{ .text = org_name } },
    );
    try db.execParams(
        "INSERT INTO memberships (user_id, org_id, role) VALUES (?, ?, ?)",
        &.{ .{ .int = user_id }, .{ .text = org_id }, .{ .text = "admin" } },
    );
    try db.execParams(
        "INSERT INTO subscriptions (org_id, status) VALUES (?, ?)",
        &.{ .{ .text = org_id }, .{ .text = "inactive" } },
    );
    try db.commit();

    const token = try issueToken(allocator, jwt_secret, user_id, org_id, "admin", jwt_ttl_sec);
    const refresh_token = try issueRefreshToken(db, allocator, user_id);
    const verify_token = try issueVerifyToken(db, allocator, user_id);
    const email_owned = try allocator.dupe(u8, email);
    const name_owned = try allocator.dupe(u8, name);
    return .{
        .token = token,
        .refresh_token = refresh_token,
        .verify_token = verify_token,
        .user_id = user_id,
        .email = email_owned,
        .name = name_owned,
        .org_id = org_id,
        .role = try allocator.dupe(u8, "admin"),
        .email_verified = false,
    };
}

pub fn signIn(
    db: *zfinal.DB,
    allocator: std.mem.Allocator,
    email: []const u8,
    pw: []const u8,
    jwt_secret: []const u8,
    jwt_ttl_sec: i64,
) !AuthResult {
    var rs = try db.queryParams(
        "SELECT id, email, name, password_hash, email_verified_at FROM users WHERE email = ?",
        &.{.{ .text = email }},
    );
    defer rs.deinit();
    if (!rs.next()) return error.Unauthorized;
    const id = (try rs.getInt(0)).?;
    const email_db = try allocator.dupe(u8, rs.getText(1).?);
    errdefer allocator.free(email_db);
    const name_db = try allocator.dupe(u8, rs.getText(2).?);
    errdefer allocator.free(name_db);
    const hash = rs.getText(3).?;
    if (!password.verify(allocator, hash, pw)) return error.Unauthorized;

    // Prefer first membership as active org.
    var mrs = try db.queryParams(
        "SELECT org_id, role FROM memberships WHERE user_id = ? ORDER BY id ASC LIMIT 1",
        &.{.{ .int = id }},
    );
    defer mrs.deinit();
    var org_id: ?[]const u8 = null;
    var role: ?[]const u8 = null;
    if (mrs.next()) {
        org_id = try allocator.dupe(u8, mrs.getText(0).?);
        role = try allocator.dupe(u8, mrs.getText(1).?);
    }

    const token = try issueToken(allocator, jwt_secret, id, org_id, role, jwt_ttl_sec);
    const refresh_token = try issueRefreshToken(db, allocator, id);
    return .{
        .token = token,
        .refresh_token = refresh_token,
        .user_id = id,
        .email = email_db,
        .name = name_db,
        .org_id = org_id,
        .role = role,
        .email_verified = rs.getText(4) != null,
    };
}

pub fn findUser(db: *zfinal.DB, allocator: std.mem.Allocator, user_id: i64) !?UserRow {
    var rs = try db.queryParams(
        "SELECT id, email, name, locale FROM users WHERE id = ?",
        &.{.{ .int = user_id }},
    );
    defer rs.deinit();
    if (!rs.next()) return null;
    return .{
        .id = (try rs.getInt(0)).?,
        .email = try allocator.dupe(u8, rs.getText(1).?),
        .name = try allocator.dupe(u8, rs.getText(2).?),
        .locale = try allocator.dupe(u8, rs.getText(3).?),
    };
}

pub fn requestPasswordReset(
    db: *zfinal.DB,
    allocator: std.mem.Allocator,
    email: []const u8,
    email_sender: *const state.EmailSender,
) !?[]const u8 {
    var rs = try db.queryParams("SELECT id FROM users WHERE email = ?", &.{.{ .text = email }});
    defer rs.deinit();
    if (!rs.next()) return null;
    const user_id = (try rs.getInt(0)).?;
    const raw = try util.randomHex(allocator, 24);
    defer allocator.free(raw);
    const th = try util.sha256Hex(allocator, raw);
    defer allocator.free(th);
    const expires = try std.fmt.allocPrint(allocator, "{d}", .{util.nowUnix() + 3600});
    defer allocator.free(expires);
    try db.execParams(
        "INSERT INTO auth_tokens (user_id, type, token_hash, expires_at) VALUES (?, ?, ?, ?)",
        &.{
            .{ .int = user_id },
            .{ .text = "password_reset" },
            .{ .text = th },
            .{ .text = expires },
        },
    );
    const body = try std.fmt.allocPrint(allocator, "Reset token: {s}", .{raw});
    defer allocator.free(body);
    email_sender.send(email, "Password reset", body);
    return try allocator.dupe(u8, raw);
}

pub fn resetPassword(db: *zfinal.DB, allocator: std.mem.Allocator, raw_token: []const u8, new_pw: []const u8) !void {
    if (isWeak(new_pw)) return error.WeakPassword;
    const th = try util.sha256Hex(allocator, raw_token);
    defer allocator.free(th);
    var rs = try db.queryParams(
        "SELECT id, user_id, expires_at, used_at FROM auth_tokens WHERE token_hash = ? AND type = ?",
        &.{ .{ .text = th }, .{ .text = "password_reset" } },
    );
    defer rs.deinit();
    if (!rs.next()) return error.NotFound;
    const token_id = (try rs.getInt(0)).?;
    const user_id = (try rs.getInt(1)).?;
    const expires = try std.fmt.parseInt(i64, rs.getText(2).?, 10);
    if (rs.getText(3) != null) return error.Gone;
    if (util.nowUnix() > expires) return error.Gone;

    const hash = try password.hash(allocator, new_pw);
    defer allocator.free(hash);
    try db.begin();
    errdefer db.rollback() catch {};
    try db.execParams("UPDATE users SET password_hash = ?, updated_at = datetime('now') WHERE id = ?", &.{
        .{ .text = hash },
        .{ .int = user_id },
    });
    try db.execParams("UPDATE auth_tokens SET used_at = datetime('now') WHERE id = ?", &.{.{ .int = token_id }});
    try db.commit();
}

/// Issue a single-use email-verification token (24h), returns the raw token.
fn issueVerifyToken(db: *zfinal.DB, allocator: std.mem.Allocator, user_id: i64) ![]u8 {
    return insertAuthToken(db, allocator, user_id, "verify_email", 24 * 3600);
}

/// Issue a rotating refresh token (30d), returns the raw token.
fn issueRefreshToken(db: *zfinal.DB, allocator: std.mem.Allocator, user_id: i64) ![]u8 {
    return insertAuthToken(db, allocator, user_id, "refresh", 30 * 24 * 3600);
}

fn insertAuthToken(db: *zfinal.DB, allocator: std.mem.Allocator, user_id: i64, token_type: []const u8, ttl_sec: i64) ![]u8 {
    const raw = try util.randomHex(allocator, 32);
    errdefer allocator.free(raw);
    const th = try util.sha256Hex(allocator, raw);
    defer allocator.free(th);
    const expires = try std.fmt.allocPrint(allocator, "{d}", .{util.nowUnix() + ttl_sec});
    defer allocator.free(expires);
    try db.execParams(
        "INSERT INTO auth_tokens (user_id, type, token_hash, expires_at) VALUES (?, ?, ?, ?)",
        &.{
            .{ .int = user_id },
            .{ .text = token_type },
            .{ .text = th },
            .{ .text = expires },
        },
    );
    return raw;
}

/// Mark `email_verified_at` using a `verify_email` token (single-use, 24h).
pub fn verifyEmail(db: *zfinal.DB, allocator: std.mem.Allocator, raw_token: []const u8) !void {
    const th = try util.sha256Hex(allocator, raw_token);
    defer allocator.free(th);
    var rs = try db.queryParams(
        "SELECT id, user_id, expires_at, used_at FROM auth_tokens WHERE token_hash = ? AND type = ?",
        &.{ .{ .text = th }, .{ .text = "verify_email" } },
    );
    defer rs.deinit();
    if (!rs.next()) return error.NotFound;
    const token_id = (try rs.getInt(0)).?;
    const user_id = (try rs.getInt(1)).?;
    const expires = try std.fmt.parseInt(i64, rs.getText(2).?, 10);
    if (rs.getText(3) != null) return error.Gone;
    if (util.nowUnix() > expires) return error.Gone;
    try db.begin();
    errdefer db.rollback() catch {};
    try db.execParams("UPDATE users SET email_verified_at = datetime('now'), updated_at = datetime('now') WHERE id = ?", &.{.{ .int = user_id }});
    try db.execParams("UPDATE auth_tokens SET used_at = datetime('now') WHERE id = ?", &.{.{ .int = token_id }});
    try db.commit();
}

/// Rotate a refresh token: validate, mark used, issue a fresh access token +
/// a new refresh token. Returns the new session.
pub fn refreshSession(
    db: *zfinal.DB,
    allocator: std.mem.Allocator,
    raw_refresh: []const u8,
    jwt_secret: []const u8,
    jwt_ttl_sec: i64,
) !AuthResult {
    const th = try util.sha256Hex(allocator, raw_refresh);
    defer allocator.free(th);
    var rs = try db.queryParams(
        "SELECT id, user_id, expires_at, used_at FROM auth_tokens WHERE token_hash = ? AND type = ?",
        &.{ .{ .text = th }, .{ .text = "refresh" } },
    );
    defer rs.deinit();
    if (!rs.next()) return error.Unauthorized;
    const token_id = (try rs.getInt(0)).?;
    const user_id = (try rs.getInt(1)).?;
    const expires = try std.fmt.parseInt(i64, rs.getText(2).?, 10);
    if (rs.getText(3) != null) return error.Unauthorized;
    if (util.nowUnix() > expires) return error.Unauthorized;

    var urs = try db.queryParams(
        "SELECT email, name, email_verified_at FROM users WHERE id = ?",
        &.{.{ .int = user_id }},
    );
    defer urs.deinit();
    if (!urs.next()) return error.Unauthorized;
    const email_db = try allocator.dupe(u8, urs.getText(0).?);
    errdefer allocator.free(email_db);
    const name_db = try allocator.dupe(u8, urs.getText(1).?);
    errdefer allocator.free(name_db);
    const verified = urs.getText(2) != null;

    var mrs = try db.queryParams(
        "SELECT org_id, role FROM memberships WHERE user_id = ? ORDER BY id ASC LIMIT 1",
        &.{.{ .int = user_id }},
    );
    defer mrs.deinit();
    var org_id: ?[]const u8 = null;
    var role: ?[]const u8 = null;
    if (mrs.next()) {
        org_id = try allocator.dupe(u8, mrs.getText(0).?);
        role = try allocator.dupe(u8, mrs.getText(1).?);
    }

    try db.begin();
    errdefer db.rollback() catch {};
    // Rotate: mark old refresh used, mint a new one.
    try db.execParams("UPDATE auth_tokens SET used_at = datetime('now') WHERE id = ?", &.{.{ .int = token_id }});
    const new_refresh = try issueRefreshToken(db, allocator, user_id);
    try db.commit();

    const token = try issueToken(allocator, jwt_secret, user_id, org_id, role, jwt_ttl_sec);
    return .{
        .token = token,
        .refresh_token = new_refresh,
        .user_id = user_id,
        .email = email_db,
        .name = name_db,
        .org_id = org_id,
        .role = role,
        .email_verified = verified,
    };
}

/// Revoke a refresh token (logout elsewhere).
pub fn revokeRefresh(db: *zfinal.DB, allocator: std.mem.Allocator, raw_refresh: []const u8) !void {
    const th = try util.sha256Hex(allocator, raw_refresh);
    defer allocator.free(th);
    _ = try db.execParams(
        "UPDATE auth_tokens SET used_at = datetime('now') WHERE token_hash = ? AND type = ? AND used_at IS NULL",
        &.{ .{ .text = th }, .{ .text = "refresh" } },
    );
}

pub fn issueToken(
    allocator: std.mem.Allocator,
    secret: []const u8,
    user_id: i64,
    org_id: ?[]const u8,
    role: ?[]const u8,
    ttl_sec: i64,
) ![]u8 {
    var sub_buf: [32]u8 = undefined;
    const sub = try std.fmt.bufPrint(&sub_buf, "{d}", .{user_id});
    const now = util.nowUnix();
    return try zfinal.jwtSign(allocator, secret, .{
        .sub = sub,
        .exp = now + ttl_sec,
        .iat = now,
        .aud = org_id,
        .role = role,
        .iss = "zfinal-saas-kit",
    });
}

pub fn freeAuthResult(allocator: std.mem.Allocator, r: AuthResult) void {
    allocator.free(r.token);
    if (r.refresh_token) |rt| allocator.free(rt);
    if (r.verify_token) |vt| allocator.free(vt);
    allocator.free(r.email);
    allocator.free(r.name);
    if (r.org_id) |o| allocator.free(o);
    if (r.role) |role| allocator.free(role);
}
