// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");
const service = @import("service.gen.zig");
const pool_ref = &@import("../../../../deps.zig").pool;
const token_ref = &@import("../../../../deps.zig").tokenMgr;
const limit_ref = &@import("../../../../deps.zig").rateLimiter;

fn err(ctx: *zfinal.Context, status: std.http.Status, comptime msg: []const u8, code: i32) !void {
    ctx.res_status = status;
    try ctx.renderJson(.{ .err = msg, .code = code });
}

/// CSRF guard: validates csrf_token using TokenManager.
fn csrfGuard(ctx: *zfinal.Context) !void {
    const token = try ctx.getPara("csrf_token") orelse return err(ctx, .forbidden, "Missing CSRF token", 40301);
    if (!try token_ref.validate(token)) return err(ctx, .forbidden, "Invalid CSRF token", 40302);
}

/// List SystemOauth2Client records with pagination + rate limiting.
pub fn list(ctx: *zfinal.Context) !void {
    limit_ref.handle(ctx) catch {};
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
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

/// Show SystemOauth2Client by ID.
pub fn show(ctx: *zfinal.Context) !void {
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    const item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    defer item.deinit(ctx.allocator);
    try ctx.renderJson(.{ .data = item });
}

/// Create SystemOauth2Client record (CSRF-protected).
pub fn create(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    const data: service.Data = .{
        .client_id = (try ctx.getPara("client_id")) orelse "",
        .secret = (try ctx.getPara("secret")) orelse "",
        .name = (try ctx.getPara("name")) orelse "",
        .logo = (try ctx.getPara("logo")) orelse "",
        .description = (try ctx.getPara("description")) orelse null,
        .status = std.fmt.parseInt(i64, (try ctx.getPara("status")) orelse "0", 10) catch 0,
        .access_token_validity_seconds = std.fmt.parseInt(i64, (try ctx.getPara("access_token_validity_seconds")) orelse "0", 10) catch 0,
        .refresh_token_validity_seconds = std.fmt.parseInt(i64, (try ctx.getPara("refresh_token_validity_seconds")) orelse "0", 10) catch 0,
        .redirect_uris = (try ctx.getPara("redirect_uris")) orelse "",
        .authorized_grant_types = (try ctx.getPara("authorized_grant_types")) orelse "",
        .scopes = (try ctx.getPara("scopes")) orelse null,
        .auto_approve_scopes = (try ctx.getPara("auto_approve_scopes")) orelse null,
        .authorities = (try ctx.getPara("authorities")) orelse null,
        .resource_ids = (try ctx.getPara("resource_ids")) orelse null,
        .additional_information = (try ctx.getPara("additional_information")) orelse null,
        .creator = (try ctx.getPara("creator")) orelse null,
        .create_time = (try ctx.getPara("create_time")) orelse "",
        .updater = (try ctx.getPara("updater")) orelse null,
        .update_time = (try ctx.getPara("update_time")) orelse "",
        .deleted = if ((try ctx.getPara("deleted"))) |v| (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "t")) else false,
    };
    const instance = service.create(db, data) catch |e| {
        if (e == error.ValidationError) return err(ctx, .unprocessable_entity, "Validation failed", 42201);
        return e;
    };
    try ctx.renderJson(.{ .ok = true, .id = instance.id });
}

/// Update SystemOauth2Client record (CSRF-protected).
pub fn update(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    if (try ctx.getPara("client_id")) |v| item.data.client_id = v;
    if (try ctx.getPara("secret")) |v| item.data.secret = v;
    if (try ctx.getPara("name")) |v| item.data.name = v;
    if (try ctx.getPara("logo")) |v| item.data.logo = v;
    if (try ctx.getPara("description")) |v| item.data.description = v;
    if (try ctx.getPara("status")) |v| item.data.status = std.fmt.parseInt(i64, v, 10) catch item.data.status;
    if (try ctx.getPara("access_token_validity_seconds")) |v| item.data.access_token_validity_seconds = std.fmt.parseInt(i64, v, 10) catch item.data.access_token_validity_seconds;
    if (try ctx.getPara("refresh_token_validity_seconds")) |v| item.data.refresh_token_validity_seconds = std.fmt.parseInt(i64, v, 10) catch item.data.refresh_token_validity_seconds;
    if (try ctx.getPara("redirect_uris")) |v| item.data.redirect_uris = v;
    if (try ctx.getPara("authorized_grant_types")) |v| item.data.authorized_grant_types = v;
    if (try ctx.getPara("scopes")) |v| item.data.scopes = v;
    if (try ctx.getPara("auto_approve_scopes")) |v| item.data.auto_approve_scopes = v;
    if (try ctx.getPara("authorities")) |v| item.data.authorities = v;
    if (try ctx.getPara("resource_ids")) |v| item.data.resource_ids = v;
    if (try ctx.getPara("additional_information")) |v| item.data.additional_information = v;
    if (try ctx.getPara("creator")) |v| item.data.creator = v;
    if (try ctx.getPara("create_time")) |v| item.data.create_time = v;
    if (try ctx.getPara("updater")) |v| item.data.updater = v;
    if (try ctx.getPara("update_time")) |v| item.data.update_time = v;
    if (try ctx.getPara("deleted")) |v| item.data.deleted = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    // Validation handled by service layer
    try item.save(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Delete SystemOauth2Client record (CSRF-protected).
pub fn delete(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    try item.delete(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Partial update SystemOauth2Client record (CSRF-protected, PATCH).
pub fn patch(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    if (try ctx.getPara("client_id")) |v| item.data.client_id = v;
    if (try ctx.getPara("secret")) |v| item.data.secret = v;
    if (try ctx.getPara("name")) |v| item.data.name = v;
    if (try ctx.getPara("logo")) |v| item.data.logo = v;
    if (try ctx.getPara("description")) |v| item.data.description = v;
    if (try ctx.getPara("status")) |v| item.data.status = std.fmt.parseInt(i64, v, 10) catch item.data.status;
    if (try ctx.getPara("access_token_validity_seconds")) |v| item.data.access_token_validity_seconds = std.fmt.parseInt(i64, v, 10) catch item.data.access_token_validity_seconds;
    if (try ctx.getPara("refresh_token_validity_seconds")) |v| item.data.refresh_token_validity_seconds = std.fmt.parseInt(i64, v, 10) catch item.data.refresh_token_validity_seconds;
    if (try ctx.getPara("redirect_uris")) |v| item.data.redirect_uris = v;
    if (try ctx.getPara("authorized_grant_types")) |v| item.data.authorized_grant_types = v;
    if (try ctx.getPara("scopes")) |v| item.data.scopes = v;
    if (try ctx.getPara("auto_approve_scopes")) |v| item.data.auto_approve_scopes = v;
    if (try ctx.getPara("authorities")) |v| item.data.authorities = v;
    if (try ctx.getPara("resource_ids")) |v| item.data.resource_ids = v;
    if (try ctx.getPara("additional_information")) |v| item.data.additional_information = v;
    if (try ctx.getPara("creator")) |v| item.data.creator = v;
    if (try ctx.getPara("create_time")) |v| item.data.create_time = v;
    if (try ctx.getPara("updater")) |v| item.data.updater = v;
    if (try ctx.getPara("update_time")) |v| item.data.update_time = v;
    if (try ctx.getPara("deleted")) |v| item.data.deleted = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
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
