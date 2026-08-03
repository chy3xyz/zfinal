//! Super-admin HTTP (P3): JSON endpoints + a minimal HTML dashboard.
//! Access: `SUPER_ADMIN_EMAILS` env (comma-separated) + valid JWT.
const std = @import("std");
const zfinal = @import("zfinal");
const service = @import("service.zig");
const state_mod = @import("../../state.zig");
const json_api = @import("../../json_api.zig");

fn requireSuper(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    const sub = ctx.getAttr("jwt_sub") orelse {
        try json_api.err(ctx, .unauthorized, "jwt");
        return error.Unauthorized;
    };
    const user_id = std.fmt.parseInt(i64, sub, 10) catch {
        try json_api.err(ctx, .unauthorized, "jwt");
        return error.Unauthorized;
    };
    if (!try service.isSuperAdmin(st.db, ctx.allocator, user_id, st.super_admin_csv)) {
        try json_api.err(ctx, .forbidden, "admin_required");
        return error.Forbidden;
    }
}

fn pageParams(ctx: *zfinal.Context) !struct { page: usize, size: usize } {
    const page = try ctx.getParaToLongDefault("page", 1);
    const size = try ctx.getParaToLongDefault("size", 20);
    return .{ .page = @intCast(@max(page, 1)), .size = @intCast(std.math.clamp(size, 1, 100)) };
}

pub fn overview(ctx: *zfinal.Context) !void {
    try requireSuper(ctx);
    const st = try state_mod.fromContext(ctx);
    try json_api.ok(ctx, try service.overview(st.db));
}

pub fn users(ctx: *zfinal.Context) !void {
    try requireSuper(ctx);
    const st = try state_mod.fromContext(ctx);
    const p = try pageParams(ctx);
    const rows = try service.listUsers(st.db, ctx.allocator, p.page, p.size);
    defer service.freeUsers(ctx.allocator, rows);
    try json_api.okMeta(ctx, rows, .{ .page = p.page, .size = p.size });
}

pub fn subscriptions(ctx: *zfinal.Context) !void {
    try requireSuper(ctx);
    const st = try state_mod.fromContext(ctx);
    const p = try pageParams(ctx);
    const rows = try service.listSubscriptions(st.db, ctx.allocator, p.page, p.size);
    defer service.freeSubs(ctx.allocator, rows);
    try json_api.okMeta(ctx, rows, .{ .page = p.page, .size = p.size });
}

/// Minimal HTML dashboard (counts only — no user data, nothing to escape).
pub fn dashboard(ctx: *zfinal.Context) !void {
    try requireSuper(ctx);
    const st = try state_mod.fromContext(ctx);
    const o = try service.overview(st.db);
    const html = try std.fmt.allocPrint(ctx.allocator,
        \\<!doctype html><html><head><meta charset="utf-8"><title>zfsaas Admin</title>
        \\<style>body{{font-family:ui-monospace,monospace;max-width:640px;margin:40px auto;padding:0 16px}}
        \\h1{{font-size:20px}}.c{{display:grid;grid-template-columns:1fr 1fr;gap:8px}}
        \\.card{{border:1px solid #ddd;border-radius:8px;padding:12px}}
        \\.n{{font-size:28px;font-weight:600}}.l{{color:#666;font-size:12px}}
        \\</style></head><body>
        \\<h1>zfsaas · Admin</h1>
        \\<div class="c">
        \\<div class="card"><div class="n">{d}</div><div class="l">users</div></div>
        \\<div class="card"><div class="n">{d}</div><div class="l">organizations</div></div>
        \\<div class="card"><div class="n">{d}</div><div class="l">active subscriptions</div></div>
        \\<div class="card"><div class="n">{d}</div><div class="l">todos</div></div>
        \\</div>
        \\<p><a href="/api/admin/users">/api/admin/users</a> ·
        \\<a href="/api/admin/subscriptions">/api/admin/subscriptions</a> ·
        \\<a href="/api/admin/overview">/api/admin/overview</a></p>
        \\</body></html>
    , .{ o.users, o.orgs, o.active_subs, o.todos });
    defer ctx.allocator.free(html);
    try ctx.renderHtml(html);
}
