//! Org / membership / invitation domain.
const std = @import("std");
const zfinal = @import("zfinal");
const util = @import("../../util.zig");
const auth_service = @import("../auth/service.zig");
const state = @import("../../state.zig");

pub const OrgRow = struct {
    id: []const u8,
    name: []const u8,
    role: []const u8,
};

pub fn listOrgs(db: *zfinal.DB, allocator: std.mem.Allocator, user_id: i64) ![]OrgRow {
    var rs = try db.queryParams(
        \\SELECT o.id, o.name, m.role
        \\FROM organizations o
        \\JOIN memberships m ON m.org_id = o.id
        \\WHERE m.user_id = ?
        \\ORDER BY o.created_at ASC
    ,
        &.{.{ .int = user_id }},
    );
    defer rs.deinit();
    var list: std.ArrayList(OrgRow) = .empty;
    errdefer {
        for (list.items) |o| {
            allocator.free(o.id);
            allocator.free(o.name);
            allocator.free(o.role);
        }
        list.deinit(allocator);
    }
    while (rs.next()) {
        try list.append(allocator, .{
            .id = try allocator.dupe(u8, rs.getText(0).?),
            .name = try allocator.dupe(u8, rs.getText(1).?),
            .role = try allocator.dupe(u8, rs.getText(2).?),
        });
    }
    return try list.toOwnedSlice(allocator);
}

pub fn freeOrgs(allocator: std.mem.Allocator, rows: []OrgRow) void {
    for (rows) |o| {
        allocator.free(o.id);
        allocator.free(o.name);
        allocator.free(o.role);
    }
    allocator.free(rows);
}

pub fn createOrg(db: *zfinal.DB, allocator: std.mem.Allocator, user_id: i64, name: []const u8) ![]u8 {
    if (name.len == 0) return error.ValidationError;
    const org_id = try util.randomHex(allocator, 12);
    errdefer allocator.free(org_id);
    try db.begin();
    errdefer db.rollback() catch {};
    try db.execParams("INSERT INTO organizations (id, name) VALUES (?, ?)", &.{
        .{ .text = org_id },
        .{ .text = name },
    });
    try db.execParams("INSERT INTO memberships (user_id, org_id, role) VALUES (?, ?, ?)", &.{
        .{ .int = user_id },
        .{ .text = org_id },
        .{ .text = "admin" },
    });
    try db.execParams("INSERT INTO subscriptions (org_id, status) VALUES (?, ?)", &.{
        .{ .text = org_id },
        .{ .text = "inactive" },
    });
    try db.commit();
    return org_id;
}

pub fn membershipRole(db: *zfinal.DB, allocator: std.mem.Allocator, user_id: i64, org_id: []const u8) !?[]u8 {
    var rs = try db.queryParams(
        "SELECT role FROM memberships WHERE user_id = ? AND org_id = ?",
        &.{ .{ .int = user_id }, .{ .text = org_id } },
    );
    defer rs.deinit();
    if (!rs.next()) return null;
    return try allocator.dupe(u8, rs.getText(0).?);
}

pub fn switchOrg(
    db: *zfinal.DB,
    allocator: std.mem.Allocator,
    user_id: i64,
    org_id: []const u8,
    jwt_secret: []const u8,
    jwt_ttl_sec: i64,
) ![]u8 {
    const role = try membershipRole(db, allocator, user_id, org_id) orelse return error.Forbidden;
    defer allocator.free(role);
    return try auth_service.issueToken(allocator, jwt_secret, user_id, org_id, role, jwt_ttl_sec);
}

pub const InviteResult = struct {
    invite_id: i64,
    raw_token: []const u8,
};

pub fn createInvite(
    db: *zfinal.DB,
    allocator: std.mem.Allocator,
    org_id: []const u8,
    email: []const u8,
    role: []const u8,
    invited_by: i64,
    email_sender: *const state.EmailSender,
) !InviteResult {
    if (!std.mem.eql(u8, role, "admin") and !std.mem.eql(u8, role, "member")) return error.ValidationError;
    const raw = try util.randomHex(allocator, 24);
    errdefer allocator.free(raw);
    const th = try util.sha256Hex(allocator, raw);
    defer allocator.free(th);
    const expires = try std.fmt.allocPrint(allocator, "{d}", .{util.nowUnix() + 7 * 24 * 3600});
    defer allocator.free(expires);
    try db.execParams(
        "INSERT INTO invitations (org_id, email, role, token_hash, invited_by, expires_at) VALUES (?, ?, ?, ?, ?, ?)",
        &.{
            .{ .text = org_id },
            .{ .text = email },
            .{ .text = role },
            .{ .text = th },
            .{ .int = invited_by },
            .{ .text = expires },
        },
    );
    const id = try db.lastInsertId();
    const body = try std.fmt.allocPrint(allocator, "Invite token: {s}", .{raw});
    defer allocator.free(body);
    email_sender.send(email, "Org invitation", body);
    return .{ .invite_id = id, .raw_token = raw };
}

pub fn acceptInvite(
    db: *zfinal.DB,
    allocator: std.mem.Allocator,
    user_id: i64,
    user_email: []const u8,
    raw_token: []const u8,
) ![]u8 {
    const th = try util.sha256Hex(allocator, raw_token);
    defer allocator.free(th);
    var rs = try db.queryParams(
        "SELECT id, org_id, email, role, expires_at, accepted_at FROM invitations WHERE token_hash = ?",
        &.{.{ .text = th }},
    );
    defer rs.deinit();
    if (!rs.next()) return error.NotFound;
    const invite_id = (try rs.getInt(0)).?;
    const org_id = try allocator.dupe(u8, rs.getText(1).?);
    errdefer allocator.free(org_id);
    const inv_email = rs.getText(2).?;
    const role = try allocator.dupe(u8, rs.getText(3).?);
    defer allocator.free(role);
    const expires = try std.fmt.parseInt(i64, rs.getText(4).?, 10);
    if (rs.getText(5) != null) return error.Gone;
    if (util.nowUnix() > expires) return error.Gone;
    if (!std.ascii.eqlIgnoreCase(inv_email, user_email)) return error.Forbidden;

    try db.begin();
    errdefer db.rollback() catch {};
    db.execParams(
        "INSERT INTO memberships (user_id, org_id, role) VALUES (?, ?, ?)",
        &.{ .{ .int = user_id }, .{ .text = org_id }, .{ .text = role } },
    ) catch {
        // already member — still mark invite accepted
    };
    try db.execParams("UPDATE invitations SET accepted_at = datetime('now') WHERE id = ?", &.{.{ .int = invite_id }});
    try db.commit();
    return org_id;
}
