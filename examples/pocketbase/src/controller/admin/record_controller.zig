const std = @import("std");
const zfinal = @import("zfinal");
const State = @import("../../state.zig");

fn getDb() *zfinal.DB {
    return State.global_state.?.db;
}

fn redirect(ctx: *zfinal.Context, url: []const u8) !void {
    ctx.res_status = .found;
    try ctx.setHeader("Location", url);
}

pub fn list(ctx: *zfinal.Context) !void {
    const session = try ctx.getCookie("admin_session");
    if (session == null or !std.mem.eql(u8, session.?, "true")) {
        try redirect(ctx, "/admin/login");
        return;
    }

    const table = ctx.getPathParam("table") orelse {
        try redirect(ctx, "/admin/collections");
        return;
    };
    const db = getDb();

    const sql = try std.fmt.allocPrintZ(ctx.allocator, "SELECT * FROM {s} ORDER BY created_at DESC LIMIT 50", .{table});
    defer ctx.allocator.free(sql);

    var rs = try db.query(sql);
    defer rs.deinit();

    var html = std.ArrayList(u8).init(ctx.allocator);
    defer html.deinit();

    try html.writer().writeAll("<html><body style='font-family:sans-serif;padding:20px;background:#f5f5f5'><div style='max-width:800px;margin:0 auto'><h1>Records: ");
    try html.writer().print("{s}</h1>", .{table});
    try html.writer().writeAll("<p><a href='/admin/collections'>Back</a> | <a href='/admin/logout'>Logout</a></p><ul>");

    while (rs.next()) {
        const row = rs.getCurrentRowMap().?;
        const id = row.get("id").?;
        try html.writer().print("<li>{s}</li>", .{id});
    }

    try html.writer().writeAll("</ul></div></body></html>");
    try ctx.renderHtml(html.items);
}

pub fn create(ctx: *zfinal.Context) !void {
    const table = ctx.getPathParam("table") orelse {
        try redirect(ctx, "/admin/collections");
        return;
    };
    const db = getDb();

    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    var id_buf: [32]u8 = undefined;
    const new_id = std.fmt.bufPrint(&id_buf, "{s}", .{std.fmt.fmtSliceHexLower(&random_bytes)}) catch "error";
    const now = std.time.timestamp();

    const sql = try std.fmt.allocPrintZ(ctx.allocator, "INSERT INTO {s} (id, created_at) VALUES ('{s}', {d})", .{ table, new_id, now });
    defer ctx.allocator.free(sql);
    try db.exec(sql);

    const redirect_url = try std.fmt.allocPrintZ(ctx.allocator, "/admin/collections/{s}/records", .{table});
    defer ctx.allocator.free(redirect_url);
    try redirect(ctx, redirect_url);
}

pub fn delete(ctx: *zfinal.Context) !void {
    const table = ctx.getPathParam("table") orelse {
        try redirect(ctx, "/admin/collections");
        return;
    };
    const id = ctx.getPathParam("id") orelse {
        try redirect(ctx, "/admin/collections");
        return;
    };
    const db = getDb();

    const sql = try std.fmt.allocPrintZ(ctx.allocator, "DELETE FROM {s} WHERE id = '{s}'", .{ table, id });
    defer ctx.allocator.free(sql);
    try db.exec(sql);

    const redirect_url = try std.fmt.allocPrintZ(ctx.allocator, "/admin/collections/{s}/records", .{table});
    defer ctx.allocator.free(redirect_url);
    try redirect(ctx, redirect_url);
}
