//! Super-admin queries: platform overview, users, subscriptions (P3).
const std = @import("std");
const zfinal = @import("zfinal");

pub const Overview = struct {
    users: i64,
    orgs: i64,
    active_subs: i64,
    todos: i64,
};

/// True when `user_id`'s email is in the comma-separated `csv` allow-list
/// (case-insensitive). Empty list → nobody is admin.
pub fn isSuperAdmin(db: *zfinal.DB, allocator: std.mem.Allocator, user_id: i64, csv: []const u8) !bool {
    _ = allocator;
    if (csv.len == 0) return false;
    var rs = try db.queryParams("SELECT email FROM users WHERE id = ?", &.{.{ .int = user_id }});
    defer rs.deinit();
    if (!rs.next()) return false;
    const email = rs.getText(0).?;
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |piece| {
        const e = std.mem.trim(u8, piece, " \t\r\n");
        if (e.len > 0 and std.ascii.eqlIgnoreCase(e, email)) return true;
    }
    return false;
}

fn scalarCount(db: *zfinal.DB, sql: [:0]const u8) !i64 {
    var rs = try db.query(sql);
    defer rs.deinit();
    if (!rs.next()) return 0;
    return (try rs.getInt(0)).?;
}

pub fn overview(db: *zfinal.DB) !Overview {
    return .{
        .users = try scalarCount(db, "SELECT COUNT(*) FROM users"),
        .orgs = try scalarCount(db, "SELECT COUNT(*) FROM organizations"),
        .active_subs = try scalarCount(db, "SELECT COUNT(*) FROM subscriptions WHERE status IN ('active','trialing')"),
        .todos = try scalarCount(db, "SELECT COUNT(*) FROM todo"),
    };
}

pub const UserRow = struct {
    id: i64,
    email: []const u8,
    name: []const u8,
    locale: []const u8,
    email_verified: bool,
};

pub fn listUsers(db: *zfinal.DB, allocator: std.mem.Allocator, page: usize, size: usize) ![]UserRow {
    var rs = try db.queryParams(
        "SELECT id, email, name, locale, email_verified_at FROM users ORDER BY id DESC LIMIT ? OFFSET ?",
        &.{ .{ .int = @intCast(size) }, .{ .int = @intCast((page - 1) * size) } },
    );
    defer rs.deinit();
    var list = std.ArrayList(UserRow).empty;
    errdefer {
        for (list.items) |u| {
            allocator.free(u.email);
            allocator.free(u.name);
            allocator.free(u.locale);
        }
        list.deinit(allocator);
    }
    while (rs.next()) {
        try list.append(allocator, .{
            .id = (try rs.getInt(0)).?,
            .email = try allocator.dupe(u8, rs.getText(1).?),
            .name = try allocator.dupe(u8, rs.getText(2).?),
            .locale = try allocator.dupe(u8, rs.getText(3).?),
            .email_verified = rs.getText(4) != null,
        });
    }
    return list.toOwnedSlice(allocator);
}

pub fn freeUsers(allocator: std.mem.Allocator, rows: []UserRow) void {
    for (rows) |u| {
        allocator.free(u.email);
        allocator.free(u.name);
        allocator.free(u.locale);
    }
    allocator.free(rows);
}

pub const SubRow = struct {
    org_id: []const u8,
    status: []const u8,
    current_period_end: ?[]const u8,
};

pub fn listSubscriptions(db: *zfinal.DB, allocator: std.mem.Allocator, page: usize, size: usize) ![]SubRow {
    var rs = try db.queryParams(
        "SELECT org_id, status, current_period_end FROM subscriptions ORDER BY updated_at DESC LIMIT ? OFFSET ?",
        &.{ .{ .int = @intCast(size) }, .{ .int = @intCast((page - 1) * size) } },
    );
    defer rs.deinit();
    var list = std.ArrayList(SubRow).empty;
    errdefer {
        for (list.items) |s| {
            allocator.free(s.org_id);
            allocator.free(s.status);
            if (s.current_period_end) |p| allocator.free(p);
        }
        list.deinit(allocator);
    }
    while (rs.next()) {
        try list.append(allocator, .{
            .org_id = try allocator.dupe(u8, rs.getText(0).?),
            .status = try allocator.dupe(u8, rs.getText(1).?),
            .current_period_end = if (rs.getText(2)) |p| try allocator.dupe(u8, p) else null,
        });
    }
    return list.toOwnedSlice(allocator);
}

pub fn freeSubs(allocator: std.mem.Allocator, rows: []SubRow) void {
    for (rows) |s| {
        allocator.free(s.org_id);
        allocator.free(s.status);
        if (s.current_period_end) |p| allocator.free(p);
    }
    allocator.free(rows);
}
