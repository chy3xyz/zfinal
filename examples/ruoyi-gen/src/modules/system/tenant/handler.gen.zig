// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");
const service = @import("service.gen.zig");
const pool = @import("../../../deps.zig").getPool();
const tokenMgr = @import("../../../deps.zig").getTokenMgr();
const rateLimiter = @import("../../../deps.zig").getRateLimiter();
fn failHttp(ctx: *zfinal.Context, http_err: anyerror, comptime detail: []const u8) anyerror {
    zfinal.http_error.setDetail(ctx, detail);
    return http_err;
}

/// CSRF guard: validates csrf_token using TokenManager.
fn csrfGuard(ctx: *zfinal.Context) !void {
    const token = try ctx.getPara("csrf_token") orelse return failHttp(ctx, error.Forbidden, "csrf_token");
    if (!try tokenMgr.validate(token)) return failHttp(ctx, error.Forbidden, "csrf_token");
}

/// List SystemTenant records with pagination + rate limiting.
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

/// Show SystemTenant by ID.
pub fn show(ctx: *zfinal.Context) !void {
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    const item = try service.findById(db, id, ctx.allocator) orelse return failHttp(ctx, error.NotFound, "id");
    defer item.deinit(ctx.allocator);
    try ctx.renderJson(.{ .data = item });
}

/// Create SystemTenant record (CSRF-protected).
pub fn create(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    const data: service.Data = .{
        .name = (try ctx.getPara("name")) orelse "",
        .contact_user_id = std.fmt.parseInt(i64, (try ctx.getPara("contact_user_id")) orelse "0", 10) catch 0,
        .contact_name = (try ctx.getPara("contact_name")) orelse "",
        .contact_mobile = (try ctx.getPara("contact_mobile")) orelse null,
        .status = std.fmt.parseInt(i64, (try ctx.getPara("status")) orelse "0", 10) catch 0,
        .websites = (try ctx.getPara("websites")) orelse null,
        .package_id = std.fmt.parseInt(i64, (try ctx.getPara("package_id")) orelse "0", 10) catch 0,
        .expire_time = (try ctx.getPara("expire_time")) orelse "",
        .account_count = std.fmt.parseInt(i64, (try ctx.getPara("account_count")) orelse "0", 10) catch 0,
        .creator = (try ctx.getPara("creator")) orelse "",
        .create_time = (try ctx.getPara("create_time")) orelse "",
        .updater = (try ctx.getPara("updater")) orelse null,
        .update_time = (try ctx.getPara("update_time")) orelse "",
        .deleted = if ((try ctx.getPara("deleted"))) |v| (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "t")) else false,
    };
    const instance = service.create(db, data) catch |e| {
        if (e == error.ValidationError) return failHttp(ctx, error.UnprocessableEntity, "validation");
        return e;
    };
    try ctx.renderJson(.{ .ok = true, .id = instance.id });
}

/// Update SystemTenant record (CSRF-protected).
pub fn update(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return failHttp(ctx, error.NotFound, "id");
    if (try ctx.getPara("name")) |v| item.data.name = v;
    if (try ctx.getPara("contact_user_id")) |v| item.data.contact_user_id = std.fmt.parseInt(i64, v, 10) catch item.data.contact_user_id;
    if (try ctx.getPara("contact_name")) |v| item.data.contact_name = v;
    if (try ctx.getPara("contact_mobile")) |v| item.data.contact_mobile = v;
    if (try ctx.getPara("status")) |v| item.data.status = std.fmt.parseInt(i64, v, 10) catch item.data.status;
    if (try ctx.getPara("websites")) |v| item.data.websites = v;
    if (try ctx.getPara("package_id")) |v| item.data.package_id = std.fmt.parseInt(i64, v, 10) catch item.data.package_id;
    if (try ctx.getPara("expire_time")) |v| item.data.expire_time = v;
    if (try ctx.getPara("account_count")) |v| item.data.account_count = std.fmt.parseInt(i64, v, 10) catch item.data.account_count;
    if (try ctx.getPara("creator")) |v| item.data.creator = v;
    if (try ctx.getPara("create_time")) |v| item.data.create_time = v;
    if (try ctx.getPara("updater")) |v| item.data.updater = v;
    if (try ctx.getPara("update_time")) |v| item.data.update_time = v;
    if (try ctx.getPara("deleted")) |v| item.data.deleted = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    // Validation handled by service layer
    try item.save(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Delete SystemTenant record (CSRF-protected).
pub fn delete(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return failHttp(ctx, error.NotFound, "id");
    try item.delete(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Partial update SystemTenant record (CSRF-protected, PATCH).
pub fn patch(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return failHttp(ctx, error.NotFound, "id");
    if (try ctx.getPara("name")) |v| item.data.name = v;
    if (try ctx.getPara("contact_user_id")) |v| item.data.contact_user_id = std.fmt.parseInt(i64, v, 10) catch item.data.contact_user_id;
    if (try ctx.getPara("contact_name")) |v| item.data.contact_name = v;
    if (try ctx.getPara("contact_mobile")) |v| item.data.contact_mobile = v;
    if (try ctx.getPara("status")) |v| item.data.status = std.fmt.parseInt(i64, v, 10) catch item.data.status;
    if (try ctx.getPara("websites")) |v| item.data.websites = v;
    if (try ctx.getPara("package_id")) |v| item.data.package_id = std.fmt.parseInt(i64, v, 10) catch item.data.package_id;
    if (try ctx.getPara("expire_time")) |v| item.data.expire_time = v;
    if (try ctx.getPara("account_count")) |v| item.data.account_count = std.fmt.parseInt(i64, v, 10) catch item.data.account_count;
    if (try ctx.getPara("creator")) |v| item.data.creator = v;
    if (try ctx.getPara("create_time")) |v| item.data.create_time = v;
    if (try ctx.getPara("updater")) |v| item.data.updater = v;
    if (try ctx.getPara("update_time")) |v| item.data.update_time = v;
    if (try ctx.getPara("deleted")) |v| item.data.deleted = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    try item.save(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Parse path `:id` via extract (HttpError.BadRequest on failure).
fn parseId(ctx: *zfinal.Context) !i64 {
    return zfinal.extract.requireParamInt(ctx, i64, "id");
}
