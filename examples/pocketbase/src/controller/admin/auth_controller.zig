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

pub fn index(ctx: *zfinal.Context) !void {
    if (try ctx.getCookie("admin_session")) |session| {
        if (std.mem.eql(u8, session, "true")) {
            return doRedirect(ctx, "/admin/dashboard");
        }
    }
    return doRedirect(ctx, "/admin/login");
}

pub fn loginPage(ctx: *zfinal.Context) !void {
    const html = "<!DOCTYPE html><html><head><title>Login</title></head><body style='font-family:sans-serif;padding:50px;text-align:center;background:#f5f5f5'><div style='background:white;padding:40px;border-radius:10px;max-width:400px;margin:0 auto'><h1>Admin Login</h1><form method='POST' action='/admin/login'><input type='email' name='email' placeholder='Email' required style='padding:10px;width:100%;margin:10px 0'><input type='password' name='password' placeholder='Password' required style='padding:10px;width:100%;margin:10px 0'><button type='submit' style='background:#667eea;color:white;padding:12px;width:100%;border:none;border-radius:5px;cursor:pointer'>Login</button></form><p style='margin-top:20px;color:#666'>Demo: admin@example.com / password</p></div></body></html>";
    try ctx.renderHtml(html);
}

pub fn login(ctx: *zfinal.Context) !void {
    const email = (try ctx.getPara("email")) orelse "";
    const password = (try ctx.getPara("password")) orelse "";

    var hash_str: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(password, &hash_str, .{});
    var hash_buf: [64]u8 = undefined;
    const password_hash = std.fmt.bufPrint(&hash_buf, "{s}", .{std.fmt.fmtSliceHexLower(&hash_str)}) catch "";

    const db = getDb();
    const sql = try std.fmt.allocPrintZ(State.global_state.?.allocator, "SELECT id FROM _admins WHERE email = '{s}' AND password_hash = '{s}' LIMIT 1", .{ email, password_hash });
    defer State.global_state.?.allocator.free(sql);

    var rs = try db.query(sql);
    defer rs.deinit();

    if (rs.next()) {
        try ctx.setCookie("admin_session", "true", 86400);
        return doRedirect(ctx, "/admin/dashboard");
    }
    return doRedirect(ctx, "/admin/login?error=1");
}

pub fn logout(ctx: *zfinal.Context) !void {
    try ctx.setCookie("admin_session", "", 0);
    return doRedirect(ctx, "/admin/login");
}

pub fn dashboard(ctx: *zfinal.Context) !void {
    const session = try ctx.getCookie("admin_session");
    if (session == null or !std.mem.eql(u8, session.?, "true")) {
        return doRedirect(ctx, "/admin/login");
    }

    const html = "<html><body style='font-family:sans-serif;padding:20px;background:#f5f5f5'><div style='max-width:800px;margin:0 auto'><h1>Dashboard</h1><p>Welcome to PocketBase Lite!</p><p><a href='/admin/collections'>Manage Collections</a> | <a href='/admin/logout'>Logout</a></p></div></body></html>";
    try ctx.renderHtml(html);
}
