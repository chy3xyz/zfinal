// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");
const service = @import("service.gen.zig");
const pool = @import("../../../../deps.zig").getPool();
const tokenMgr = @import("../../../../deps.zig").getTokenMgr();
const rateLimiter = @import("../../../../deps.zig").getRateLimiter();
fn failHttp(ctx: *zfinal.Context, http_err: anyerror, comptime detail: []const u8) anyerror {
    zfinal.http_error.setDetail(ctx, detail);
    return http_err;
}

/// CSRF guard: validates csrf_token using TokenManager.
fn csrfGuard(ctx: *zfinal.Context) !void {
    const token = try ctx.getPara("csrf_token") orelse return failHttp(ctx, error.Forbidden, "csrf_token");
    if (!try tokenMgr.validate(token)) return failHttp(ctx, error.Forbidden, "csrf_token");
}

/// List SystemSocialClient records with pagination + rate limiting.
pub fn list(ctx: *zfinal.Context) !void {
    try rateLimiter.handle(ctx);
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

/// Show SystemSocialClient by ID.
pub fn show(ctx: *zfinal.Context) !void {
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    const item = try service.findById(db, id, ctx.allocator) orelse return failHttp(ctx, error.NotFound, "id");
    defer item.deinit(ctx.allocator);
    try ctx.renderJson(.{ .data = item });
}

/// Create SystemSocialClient record (CSRF-protected).
pub fn create(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    const data: service.Data = .{
        .name = (try ctx.getPara("name")) orelse "",
        .social_type = std.fmt.parseInt(i64, (try ctx.getPara("social_type")) orelse "0", 10) catch 0,
        .user_type = std.fmt.parseInt(i64, (try ctx.getPara("user_type")) orelse "0", 10) catch 0,
        .client_id = (try ctx.getPara("client_id")) orelse "",
        .client_secret = (try ctx.getPara("client_secret")) orelse "",
        .agent_id = (try ctx.getPara("agent_id")) orelse null,
        .public_key = (try ctx.getPara("public_key")) orelse null,
        .status = std.fmt.parseInt(i64, (try ctx.getPara("status")) orelse "0", 10) catch 0,
        .creator = (try ctx.getPara("creator")) orelse null,
        .create_time = (try ctx.getPara("create_time")) orelse "",
        .updater = (try ctx.getPara("updater")) orelse null,
        .update_time = (try ctx.getPara("update_time")) orelse "",
        .deleted = if ((try ctx.getPara("deleted"))) |v| (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "t")) else false,
        .tenant_id = std.fmt.parseInt(i64, (try ctx.getPara("tenant_id")) orelse "0", 10) catch 0,
    };
    const instance = service.create(db, data) catch |e| {
        if (e == error.ValidationError) return failHttp(ctx, error.UnprocessableEntity, "validation");
        return e;
    };
    try ctx.renderJson(.{ .ok = true, .id = instance.id });
}

/// Update SystemSocialClient record (CSRF-protected).
pub fn update(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return failHttp(ctx, error.NotFound, "id");
    if (try ctx.getPara("name")) |v| item.data.name = v;
    if (try ctx.getPara("social_type")) |v| item.data.social_type = std.fmt.parseInt(i64, v, 10) catch item.data.social_type;
    if (try ctx.getPara("user_type")) |v| item.data.user_type = std.fmt.parseInt(i64, v, 10) catch item.data.user_type;
    if (try ctx.getPara("client_id")) |v| item.data.client_id = v;
    if (try ctx.getPara("client_secret")) |v| item.data.client_secret = v;
    if (try ctx.getPara("agent_id")) |v| item.data.agent_id = v;
    if (try ctx.getPara("public_key")) |v| item.data.public_key = v;
    if (try ctx.getPara("status")) |v| item.data.status = std.fmt.parseInt(i64, v, 10) catch item.data.status;
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

/// Delete SystemSocialClient record (CSRF-protected).
pub fn delete(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return failHttp(ctx, error.NotFound, "id");
    try item.delete(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Partial update SystemSocialClient record (CSRF-protected, PATCH).
pub fn patch(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return failHttp(ctx, error.NotFound, "id");
    if (try ctx.getPara("name")) |v| item.data.name = v;
    if (try ctx.getPara("social_type")) |v| item.data.social_type = std.fmt.parseInt(i64, v, 10) catch item.data.social_type;
    if (try ctx.getPara("user_type")) |v| item.data.user_type = std.fmt.parseInt(i64, v, 10) catch item.data.user_type;
    if (try ctx.getPara("client_id")) |v| item.data.client_id = v;
    if (try ctx.getPara("client_secret")) |v| item.data.client_secret = v;
    if (try ctx.getPara("agent_id")) |v| item.data.agent_id = v;
    if (try ctx.getPara("public_key")) |v| item.data.public_key = v;
    if (try ctx.getPara("status")) |v| item.data.status = std.fmt.parseInt(i64, v, 10) catch item.data.status;
    if (try ctx.getPara("creator")) |v| item.data.creator = v;
    if (try ctx.getPara("create_time")) |v| item.data.create_time = v;
    if (try ctx.getPara("updater")) |v| item.data.updater = v;
    if (try ctx.getPara("update_time")) |v| item.data.update_time = v;
    if (try ctx.getPara("deleted")) |v| item.data.deleted = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("tenant_id")) |v| item.data.tenant_id = std.fmt.parseInt(i64, v, 10) catch item.data.tenant_id;
    try item.save(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Parse path `:id` via extract (HttpError.BadRequest on failure).
fn parseId(ctx: *zfinal.Context) !i64 {
    return zfinal.extract.requireParamInt(ctx, i64, "id");
}
