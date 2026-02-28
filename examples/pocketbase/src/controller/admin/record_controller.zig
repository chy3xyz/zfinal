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

    var rs = db.query(sql) catch {
        try redirect(ctx, "/admin/collections");
        return;
    };
    defer rs.deinit();

    var html = std.ArrayList(u8).init(ctx.allocator);
    defer html.deinit();

    try html.writer().writeAll(
        \\<!DOCTYPE html><html><head><title>Records</title><script src="https://cdn.tailwindcss.com"></script></head>
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
        \\        <div class="flex items-center gap-2">
        \\          <a href="/admin/collections" class="text-indigo-600 hover:text-indigo-800 transition">Collections</a>
        \\          <span class="text-gray-400">/</span>
        \\          <h1 class="text-lg font-bold">
    );
    try html.writer().print("{s}", .{table});
    try html.writer().writeAll(
        \\          </h1>
        \\        </div>
        \\        <div class="flex items-center gap-5">
        \\          <span class="text-sm font-medium text-gray-600 bg-gray-100 px-3 py-1.5 rounded-full">admin@example.com</span>
        \\          <a href="/admin/logout" class="text-sm text-gray-500 hover:text-red-600 font-medium transition flex items-center gap-1">
        \\            Logout <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1"></path></svg>
        \\          </a>
        \\        </div>
        \\      </header>
        \\      <main class="flex-1 overflow-y-auto p-6 lg:p-8">
        \\        <div class="bg-white p-6 rounded-2xl shadow-sm border border-gray-200 mb-8 flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        \\      <div>
        \\        <h2 class="text-2xl font-bold text-gray-900 flex items-center gap-2">
    );
    try html.writer().print("{s}", .{table});
    try html.writer().writeAll(
        \\        </h2>
        \\        <p class="text-sm text-gray-500 mt-1">Browse and manage data records in this collection.</p>
        \\      </div>
        \\      <div class="flex w-full sm:w-auto">
        \\        <a href="/admin/collections/
    );
    try html.writer().print("{s}", .{table});
    try html.writer().writeAll(
        \\/records/new" class="bg-indigo-600 text-white px-5 py-2 rounded-lg text-sm font-medium hover:bg-indigo-700 transition flex items-center justify-center gap-2 shadow-sm w-full sm:w-auto">
        \\          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"></path></svg> New Record
        \\        </a>
        \\      </div>
        \\    </div>
        \\    <div class="bg-white rounded-2xl shadow-sm border border-gray-200 overflow-x-auto">
        \\      <table class="w-full text-left border-collapse min-w-max">
        \\        <thead>
        \\          <tr class="bg-gray-50/50 border-b border-gray-200 text-gray-500 text-xs uppercase tracking-wider">
    );

    for (rs.columns) |col| {
        try html.writer().print("<th class=\"p-4 font-medium first:pl-6\">{s}</th>", .{col});
    }

    try html.writer().writeAll(
        \\            <th class="p-4 font-medium text-right pr-6 w-24">Actions</th>
        \\          </tr>
        \\        </thead>
        \\        <tbody class="divide-y divide-gray-100">
    );

    var count: usize = 0;
    while (rs.next()) {
        count += 1;
        const row = rs.getCurrentRowMap().?;

        try html.writer().writeAll("<tr class=\"hover:bg-indigo-50/30 transition\">");
        for (rs.columns) |col| {
            const val = row.get(col) orelse "null";
            if (std.mem.eql(u8, col, "id")) {
                try html.writer().print("<td class=\"p-4 first:pl-6 font-mono text-xs text-indigo-600 font-bold\">{s}</td>", .{val});
            } else {
                try html.writer().print("<td class=\"p-4 text-sm text-gray-700 truncate max-w-[200px]\">{s}</td>", .{val});
            }
        }

        const id = row.get("id").?;
        try html.writer().print(
            \\          <td class="p-4 pr-6 text-right">
            \\            <form method="POST" action="/admin/collections/{s}/records/{s}/delete" class="inline" onsubmit="return confirm('WARNING: Are you sure you want to delete this record?');">
            \\              <button type="submit" class="text-gray-400 hover:text-red-600 text-sm font-medium transition p-2 rounded hover:bg-red-50">
            \\                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"></path></svg>
            \\              </button>
            \\            </form>
            \\          </td>
            \\        </tr>
        , .{ table, id });
    }

    if (count == 0) {
        try html.writer().print(
            \\        <tr>
            \\          <td colspan="{d}" class="p-12 text-center text-gray-400 italic">No records found in this collection. click "New Record" to add one.</td>
            \\        </tr>
        , .{rs.columns.len + 1});
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
