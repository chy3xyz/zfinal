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
    const html =
        \\<!DOCTYPE html><html><head><title>Login</title><script src="https://cdn.tailwindcss.com"></script></head>
        \\<body class="bg-gray-100 font-sans flex items-center justify-center min-h-screen">
        \\  <div class="bg-white p-8 rounded-xl shadow-lg max-w-sm w-full">
        \\    <div class="text-center mb-6">
        \\      <h1 class="text-2xl font-bold text-gray-800">PocketBase Lite</h1>
        \\      <p class="text-gray-500 text-sm mt-1">Admin Panel Login</p>
        \\    </div>
        \\    <form method='POST' action='/admin/login' class="space-y-4">
        \\      <div>
        \\        <input type='email' name='email' placeholder='Email Address' required class="w-full px-4 py-2 border border-gray-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-transparent transition">
        \\      </div>
        \\      <div>
        \\        <input type='password' name='password' placeholder='Password' required class="w-full px-4 py-2 border border-gray-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-transparent transition">
        \\      </div>
        \\      <button type='submit' class="w-full bg-indigo-600 text-white font-medium py-2 rounded-lg hover:bg-indigo-700 transition duration-200 mt-2">Sign In</button>
        \\    </form>
        \\    <div class="mt-6 pt-4 border-t border-gray-100 text-center">
        \\      <p class="text-xs text-gray-400">Demo User: admin@example.com</p>
        \\      <p class="text-xs text-gray-400">Password: password</p>
        \\    </div>
        \\  </div>
        \\</body></html>
    ;
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

    const html =
        \\<!DOCTYPE html><html><head><title>Dashboard</title><script src="https://cdn.tailwindcss.com"></script></head>
        \\<body class="bg-gray-50 font-sans text-gray-800 h-screen hidden sm:block">
        \\  <div class="flex h-screen overflow-hidden">
        \\    <!-- Sidebar -->
        \\    <aside class="w-64 bg-slate-900 text-slate-300 flex flex-col flex-shrink-0 transition-all duration-300">
        \\      <div class="h-16 flex items-center px-6 border-b border-slate-800 font-bold text-lg tracking-wider text-white">
        \\        <svg class="w-6 h-6 text-indigo-500 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10"></path></svg>
        \\        PB Lite
        \\      </div>
        \\      <nav class="flex-1 py-6 px-3 space-y-2 overflow-y-auto">
        \\        <a href="/admin/dashboard" class="flex items-center px-3 py-2.5 text-sm font-medium rounded-lg bg-indigo-600 text-white shadow-sm">
        \\          <svg class="w-5 h-5 mr-3" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6"></path></svg> Dashboard
        \\        </a>
        \\        <a href="/admin/collections" class="flex items-center px-3 py-2.5 text-sm font-medium rounded-lg hover:bg-slate-800 hover:text-white transition group">
        \\          <svg class="w-5 h-5 mr-3 text-slate-400 group-hover:text-white transition" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 7v10c0 2.21 3.582 4 8 4s8-1.79 8-4V7M4 7c0 2.21 3.582 4 8 4s8-1.79 8-4M4 7c0-2.21 3.582-4 8-4s8 1.79 8 4m0 5c0 2.21-3.582 4-8 4s-8-1.79-8-4"></path></svg> Collections
        \\        </a>
        \\      </nav>
        \\    </aside>
        \\    <!-- Main Content -->
        \\    <div class="flex flex-col flex-1 overflow-hidden">
        \\      <header class="h-16 bg-white border-b border-gray-200 flex items-center justify-between px-6 lg:px-8 shrink-0 shadow-sm z-10">
        \\        <h1 class="text-xl font-semibold text-gray-800">Dashboard</h1>
        \\        <div class="flex items-center gap-5">
        \\          <span class="text-sm font-medium text-gray-600 bg-gray-100 px-3 py-1.5 rounded-full">admin@example.com</span>
        \\          <a href="/admin/logout" class="text-sm text-gray-500 hover:text-red-600 font-medium transition flex items-center gap-1">
        \\            Logout <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1"></path></svg>
        \\          </a>
        \\        </div>
        \\      </header>
        \\      <main class="flex-1 overflow-y-auto p-6 lg:p-8">
        \\        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        \\          <a href="/admin/collections" class="group block p-6 bg-white border border-gray-200 rounded-2xl shadow-sm hover:shadow-md hover:border-indigo-300 transition duration-200">
        \\            <div class="w-12 h-12 bg-indigo-50 text-indigo-600 rounded-xl flex items-center justify-center mb-4 group-hover:bg-indigo-600 group-hover:text-white transition">
        \\              <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10"></path></svg>
        \\            </div>
        \\            <h3 class="font-bold text-gray-900 text-lg group-hover:text-indigo-600 transition">Collections</h3>
        \\            <p class="text-sm text-gray-500 mt-2">Manage your database tables, schemas, and configure data structures.</p>
        \\          </a>
        \\          <div class="block p-6 bg-white border border-gray-200 rounded-2xl shadow-sm opacity-60">
        \\            <div class="w-12 h-12 bg-gray-50 text-gray-400 rounded-xl flex items-center justify-center mb-4">
        \\              <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4.354a4 4 0 110 5.292M15 21H3v-1a6 6 0 0112 0v1zm0 0h6v-1a6 6 0 00-9-5.197M13 7a4 4 0 11-8 0 4 4 0 018 0z"></path></svg>
        \\            </div>
        \\            <h3 class="font-bold text-gray-900 text-lg">Admins (Soon)</h3>
        \\            <p class="text-sm text-gray-500 mt-2">Manage administrator accounts and access control.</p>
        \\          </div>
        \\          <div class="block p-6 bg-white border border-gray-200 rounded-2xl shadow-sm opacity-60">
        \\            <div class="w-12 h-12 bg-gray-50 text-gray-400 rounded-xl flex items-center justify-center mb-4">
        \\              <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"></path><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"></path></svg>
        \\            </div>
        \\            <h3 class="font-bold text-gray-900 text-lg">Settings (Soon)</h3>
        \\            <p class="text-sm text-gray-500 mt-2">Configure system settings and application preferences.</p>
        \\          </div>
        \\        </div>
        \\      </main>
        \\    </div>
        \\  </div>
        \\  <div class="sm:hidden flex items-center justify-center h-screen bg-white p-6 text-center">
        \\    <div>
        \\      <svg class="w-16 h-16 text-indigo-500 mx-auto mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 18h.01M8 21h8a2 2 0 002-2V5a2 2 0 00-2-2H8a2 2 0 00-2 2v14a2 2 0 002 2z"></path></svg>
        \\      <h2 class="text-xl font-bold text-gray-900 mb-2">Desktop Only Admin</h2>
        \\      <p class="text-gray-500">Please access the admin panel from a desktop or tablet device.</p>
        \\    </div>
        \\  </div>
        \\</body></html>
    ;
    try ctx.renderHtml(html);
}
