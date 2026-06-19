// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");
const service = @import("service.gen.zig");
const pool = @import("../../../../deps.zig").getPool();
const tokenMgr = @import("../../../../deps.zig").getTokenMgr();
const rateLimiter = @import("../../../../deps.zig").getRateLimiter();
fn err(ctx: *zfinal.Context, status: std.http.Status, comptime msg: []const u8, code: i32) !void {
    ctx.res_status = status;
    try ctx.renderJson(.{ .err = msg, .code = code });
}

/// CSRF guard: validates csrf_token using TokenManager.
fn csrfGuard(ctx: *zfinal.Context) !void {
    const token = try ctx.getPara("csrf_token") orelse return err(ctx, .forbidden, "Missing CSRF token", 40301);
    if (!try tokenMgr.validate(token)) return err(ctx, .forbidden, "Invalid CSRF token", 40302);
}

/// List SystemOauth2Approve records with pagination + rate limiting.
pub fn list(ctx: *zfinal.Context) !void {
    rateLimiter.handle(ctx) catch {};
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    const page = try ctx.getParaToIntDefault("page", 1);
    const size = try ctx.getParaToIntDefault("size", 20);
    const items = try service.paginate(db, @intCast(page), @intCast(size), ctx.allocator);
    defer {
        for (items) |*it| it.deinit(ctx.allocator);
        ctx.allocator.free(items);
    }
    const total = try service.count(db);
    try ctx.renderJson(.{ .data = items, .total = total, .page = page, .size = size });
}

/// Show SystemOauth2Approve by ID.
pub fn show(ctx: *zfinal.Context) !void {
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    const item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    defer item.deinit(ctx.allocator);
    try ctx.renderJson(.{ .data = item });
}

/// Create SystemOauth2Approve record (CSRF-protected).
pub fn create(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    const data: service.Data = .{
        .user_id = std.fmt.parseInt(i64, (try ctx.getPara("user_id")) orelse "0", 10) catch 0,
        .user_type = std.fmt.parseInt(i64, (try ctx.getPara("user_type")) orelse "0", 10) catch 0,
        .client_id = (try ctx.getPara("client_id")) orelse "",
        .scope = (try ctx.getPara("scope")) orelse "",
        .approved = if ((try ctx.getPara("approved"))) |v| (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "t")) else false,
        .expires_time = (try ctx.getPara("expires_time")) orelse "",
        .creator = (try ctx.getPara("creator")) orelse null,
        .create_time = (try ctx.getPara("create_time")) orelse "",
        .updater = (try ctx.getPara("updater")) orelse null,
        .update_time = (try ctx.getPara("update_time")) orelse "",
        .deleted = if ((try ctx.getPara("deleted"))) |v| (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "t")) else false,
        .tenant_id = std.fmt.parseInt(i64, (try ctx.getPara("tenant_id")) orelse "0", 10) catch 0,
    };
    const instance = service.create(db, data) catch |e| {
        if (e == error.ValidationError) return err(ctx, .unprocessable_entity, "Validation failed", 42201);
        return e;
    };
    try ctx.renderJson(.{ .ok = true, .id = instance.id });
}

/// Update SystemOauth2Approve record (CSRF-protected).
pub fn update(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    if (try ctx.getPara("user_id")) |v| item.data.user_id = std.fmt.parseInt(i64, v, 10) catch item.data.user_id;
    if (try ctx.getPara("user_type")) |v| item.data.user_type = std.fmt.parseInt(i64, v, 10) catch item.data.user_type;
    if (try ctx.getPara("client_id")) |v| item.data.client_id = v;
    if (try ctx.getPara("scope")) |v| item.data.scope = v;
    if (try ctx.getPara("approved")) |v| item.data.approved = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("expires_time")) |v| item.data.expires_time = v;
    if (try ctx.getPara("creator")) |v| item.data.creator = v;
    if (try ctx.getPara("create_time")) |v| item.data.create_time = v;
    if (try ctx.getPara("updater")) |v| item.data.updater = v;
    if (try ctx.getPara("update_time")) |v| item.data.update_time = v;
    if (try ctx.getPara("deleted")) |v| item.data.deleted = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("tenant_id")) |v| item.data.tenant_id = std.fmt.parseInt(i64, v, 10) catch item.data.tenant_id;
    // Validation handled by service layer
    try item.save(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Delete SystemOauth2Approve record (CSRF-protected).
pub fn delete(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    try item.delete(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Partial update SystemOauth2Approve record (CSRF-protected, PATCH).
pub fn patch(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    if (try ctx.getPara("user_id")) |v| item.data.user_id = std.fmt.parseInt(i64, v, 10) catch item.data.user_id;
    if (try ctx.getPara("user_type")) |v| item.data.user_type = std.fmt.parseInt(i64, v, 10) catch item.data.user_type;
    if (try ctx.getPara("client_id")) |v| item.data.client_id = v;
    if (try ctx.getPara("scope")) |v| item.data.scope = v;
    if (try ctx.getPara("approved")) |v| item.data.approved = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("expires_time")) |v| item.data.expires_time = v;
    if (try ctx.getPara("creator")) |v| item.data.creator = v;
    if (try ctx.getPara("create_time")) |v| item.data.create_time = v;
    if (try ctx.getPara("updater")) |v| item.data.updater = v;
    if (try ctx.getPara("update_time")) |v| item.data.update_time = v;
    if (try ctx.getPara("deleted")) |v| item.data.deleted = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("tenant_id")) |v| item.data.tenant_id = std.fmt.parseInt(i64, v, 10) catch item.data.tenant_id;
    try item.save(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Parse and validate ID path parameter.
fn parseId(ctx: *zfinal.Context) !i64 {
    const id_str = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .err = "Missing ID" });
        return error.InvalidId;
    };
    return std.fmt.parseInt(i64, id_str, 10) catch {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .err = "Invalid ID" });
        return error.InvalidId;
    };
}
