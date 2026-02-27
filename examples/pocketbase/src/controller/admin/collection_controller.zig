const std = @import("std");
const zfinal = @import("zfinal");
const State = @import("../../state.zig");

fn getDb() *zfinal.DB {
    return State.global_state.?.db;
}

fn doRedirect(ctx: *zfinal.Context, location: []const u8) !void {
    ctx.res_status = .found;
    try ctx.setHeader("Location", location);
    try ctx.renderText("");
}

fn checkAuth(ctx: *zfinal.Context) bool {
    const session = ctx.getCookie("admin_session") catch null;
    return session != null and std.mem.eql(u8, session.?, "true");
}

pub fn list(ctx: *zfinal.Context) !void {
    if (!checkAuth(ctx)) return doRedirect(ctx, "/admin/login");

    const db = getDb();
    var rs = try db.query("SELECT name, type FROM _collections ORDER BY created_at DESC");
    defer rs.deinit();

    var html = std.ArrayList(u8).init(ctx.allocator);
    defer html.deinit();

    try html.writer().writeAll("<html><body style='font-family:sans-serif;padding:20px;background:#f5f5f5'><div style='max-width:800px;margin:0 auto'><h1>Collections</h1><p><a href='/admin/dashboard'>Dashboard</a> | <a href='/admin/logout'>Logout</a></p><ul>");

    while (rs.next()) {
        const row = rs.getCurrentRowMap().?;
        const name = row.get("name").?;
        try html.writer().print("<li>{s}</li>", .{name});
    }

    try html.writer().writeAll("</ul></div></body></html>");
    try ctx.renderHtml(html.items);
}

pub fn create(ctx: *zfinal.Context) !void {
    if (!checkAuth(ctx)) return doRedirect(ctx, "/admin/login");

    const name = (try ctx.getPara("name")) orelse {
        try doRedirect(ctx, "/admin/collections");
        return;
    };
    if (name.len == 0 or name.len > 64) {
        try doRedirect(ctx, "/admin/collections");
        return;
    }

    const db = getDb();
    const sql = try std.fmt.allocPrintZ(ctx.allocator, "CREATE TABLE IF NOT EXISTS {s} (id TEXT PRIMARY KEY, created_at INTEGER, updated_at INTEGER)", .{name});
    defer ctx.allocator.free(sql);
    try db.exec(sql);

    const ins_sql = try std.fmt.allocPrintZ(ctx.allocator, "INSERT INTO _collections (name, type) VALUES ('{s}', 'base')", .{name});
    defer ctx.allocator.free(ins_sql);
    try db.exec(ins_sql);

    try doRedirect(ctx, "/admin/collections");
}

pub fn delete(ctx: *zfinal.Context) !void {
    if (!checkAuth(ctx)) return doRedirect(ctx, "/admin/login");

    const name = ctx.getPathParam("name") orelse {
        try doRedirect(ctx, "/admin/collections");
        return;
    };

    const db = getDb();
    const sql = try std.fmt.allocPrintZ(ctx.allocator, "DROP TABLE IF EXISTS {s}", .{name});
    defer ctx.allocator.free(sql);
    try db.exec(sql);

    const del_sql = try std.fmt.allocPrintZ(ctx.allocator, "DELETE FROM _collections WHERE name = '{s}'", .{name});
    defer ctx.allocator.free(del_sql);
    try db.exec(del_sql);

    try doRedirect(ctx, "/admin/collections");
}
