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

    try html.writer().writeAll(
        \\<!DOCTYPE html><html><head><title>Collections</title><script src="https://cdn.tailwindcss.com"></script></head>
        \\<body class="bg-gray-50 font-sans text-gray-800 h-screen hidden sm:block">
        \\  <div class="flex h-screen overflow-hidden">
        \\    <aside class="w-64 bg-slate-900 text-slate-300 flex flex-col flex-shrink-0 transition-all duration-300">
        \\      <div class="h-16 flex items-center px-6 border-b border-slate-800 font-bold text-lg tracking-wider text-white">
        \\        <svg class="w-6 h-6 text-indigo-500 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10"></path></svg>
        \\        PB Lite
        \\      </div>
        \\      <nav class="flex-1 py-6 px-3 space-y-2 overflow-y-auto">
        \\        <a href="/admin/dashboard" class="flex items-center px-3 py-2.5 text-sm font-medium rounded-lg hover:bg-slate-800 hover:text-white transition group">
        \\          <svg class="w-5 h-5 mr-3 text-slate-400 group-hover:text-white transition" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6"></path></svg> Dashboard
        \\        </a>
        \\        <a href="/admin/collections" class="flex items-center px-3 py-2.5 text-sm font-medium rounded-lg bg-indigo-600 text-white shadow-sm">
        \\          <svg class="w-5 h-5 mr-3" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 7v10c0 2.21 3.582 4 8 4s8-1.79 8-4V7M4 7c0 2.21 3.582 4 8 4s8-1.79 8-4M4 7c0-2.21 3.582-4 8-4s8 1.79 8 4m0 5c0 2.21-3.582 4-8 4s-8-1.79-8-4"></path></svg> Collections
        \\        </a>
        \\      </nav>
        \\    </aside>
        \\    <div class="flex flex-col flex-1 overflow-hidden">
        \\      <header class="h-16 bg-white border-b border-gray-200 flex items-center justify-between px-6 lg:px-8 shrink-0 shadow-sm z-10">
        \\        <h1 class="text-xl font-semibold text-gray-800">Collections</h1>
        \\        <div class="flex items-center gap-5">
        \\          <span class="text-sm font-medium text-gray-600 bg-gray-100 px-3 py-1.5 rounded-full">admin@example.com</span>
        \\          <a href="/admin/logout" class="text-sm text-gray-500 hover:text-red-600 font-medium transition flex items-center gap-1">
        \\            Logout <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1"></path></svg>
        \\          </a>
        \\        </div>
        \\      </header>
        \\      <main class="flex-1 overflow-y-auto p-6 lg:p-8">
        \\    <div class="bg-white p-6 rounded-2xl shadow-sm border border-gray-200 mb-8 flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        \\      <div>
        \\        <h2 class="text-2xl font-bold text-gray-900">Data Collections</h2>
        \\        <p class="text-sm text-gray-500 mt-1">Manage your tables and view their records.</p>
        \\      </div>
        \\      <form method="POST" action="/admin/collections" class="flex flex-col sm:flex-row w-full sm:w-auto gap-2">
        \\        <input type="text" name="name" placeholder="Name..." required pattern="[a-zA-Z0-9_]+" class="w-full sm:w-40 px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-transparent text-sm transition">
        \\        <input type="text" name="schema" placeholder="Schema (e.g. title TEXT, age INT)" class="w-full sm:w-64 px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-transparent text-sm transition">
        \\        <button type="submit" class="bg-indigo-600 text-white px-5 py-2 rounded-lg text-sm font-medium hover:bg-indigo-700 transition flex items-center justify-center gap-1 shrink-0">
        \\          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"></path></svg> Create
        \\        </button>
        \\      </form>
        \\    </div>
        \\    <div class="bg-white rounded-2xl shadow-sm border border-gray-200 overflow-hidden">
        \\      <table class="w-full text-left border-collapse">
        \\        <thead>
        \\          <tr class="bg-gray-50/50 border-b border-gray-200 text-gray-500 text-xs uppercase tracking-wider">
        \\            <th class="p-4 font-medium pl-6">Collection Name</th>
        \\            <th class="p-4 font-medium">Type</th>
        \\            <th class="p-4 font-medium text-right pr-6">Actions</th>
        \\          </tr>
        \\        </thead>
        \\        <tbody class="divide-y divide-gray-100">
    );

    var count: usize = 0;
    while (rs.next()) {
        count += 1;
        const row = rs.getCurrentRowMap().?;
        const name = row.get("name").?;
        const t_type = row.get("type").?;
        try html.writer().print(
            \\        <tr class="hover:bg-indigo-50/30 transition group">
            \\          <td class="p-4 pl-6">
            \\            <a href="/admin/collections/{s}/records" class="font-bold text-indigo-600 hover:text-indigo-800 hover:underline flex items-center gap-2">
            \\              <svg class="w-4 h-4 text-indigo-400" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 7v10c0 2.21 3.582 4 8 4s8-1.79 8-4V7M4 7c0 2.21 3.582 4 8 4s8-1.79 8-4M4 7c0-2.21 3.582-4 8-4s8 1.79 8 4m0 5c0 2.21-3.582 4-8 4s-8-1.79-8-4"></path></svg>
            \\              {s}
            \\            </a>
            \\          </td>
            \\          <td class="p-4 text-sm text-gray-500"><span class="px-2.5 py-0.5 rounded-full bg-gray-100 border border-gray-200 text-xs font-medium">{s}</span></td>
            \\          <td class="p-4 pr-6 text-right">
            \\            <form method="POST" action="/admin/collections/{s}/delete" class="inline" onsubmit="return confirm('WARNING: Are you sure you want to delete the `{s}` collection and ALL its data?');">
            \\              <button type="submit" class="text-gray-400 hover:text-red-600 text-sm font-medium transition p-2 rounded hover:bg-red-50">
            \\                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"></path></svg>
            \\              </button>
            \\            </form>
            \\          </td>
            \\        </tr>
        , .{ name, name, t_type, name, name });
    }

    if (count == 0) {
        try html.writer().writeAll(
            \\        <tr>
            \\          <td colspan="3" class="p-8 text-center text-gray-400 italic">No collections found. Create your first table above.</td>
            \\        </tr>
        );
    }

    try html.writer().writeAll(
        \\        </tbody>
        \\      </table>
        \\    </div>
        \\  </main>
        \\  </div>
        \\  </div>
        \\  <div class="sm:hidden flex items-center justify-center h-screen bg-white p-6 text-center">
        \\    <div>
        \\      <svg class="w-16 h-16 text-indigo-500 mx-auto mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 18h.01M8 21h8a2 2 0 002-2V5a2 2 0 00-2-2H8a2 2 0 00-2 2v14a2 2 0 002 2z"></path></svg>
        \\      <h2 class="text-xl font-bold text-gray-900 mb-2">Desktop Only Admin</h2>
        \\      <p class="text-gray-500">Please access the admin panel from a desktop or tablet device.</p>
        \\    </div>
        \\  </div>
        \\</body></html>
    );
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

    const schema = (try ctx.getPara("schema")) orelse "";
    var schema_sql = std.ArrayList(u8).init(ctx.allocator);
    defer schema_sql.deinit();

    if (schema.len > 0) {
        try schema_sql.writer().print(", {s}", .{schema});
    }

    const db = getDb();
    const sql = try std.fmt.allocPrintZ(ctx.allocator, "CREATE TABLE IF NOT EXISTS {s} (id TEXT PRIMARY KEY, created_at INTEGER, updated_at INTEGER{s})", .{ name, schema_sql.items });
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
