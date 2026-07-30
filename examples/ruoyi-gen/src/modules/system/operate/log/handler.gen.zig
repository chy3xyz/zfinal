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

/// List SystemOperateLog records with pagination + rate limiting.
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

/// Show SystemOperateLog by ID.
pub fn show(ctx: *zfinal.Context) !void {
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    const item = try service.findById(db, id, ctx.allocator) orelse return failHttp(ctx, error.NotFound, "id");
    defer item.deinit(ctx.allocator);
    try ctx.renderJson(.{ .data = item });
}

/// Create SystemOperateLog record (CSRF-protected).
pub fn create(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    const data: service.Data = .{
        .trace_id = (try ctx.getPara("trace_id")) orelse "",
        .user_id = std.fmt.parseInt(i64, (try ctx.getPara("user_id")) orelse "0", 10) catch 0,
        .user_type = std.fmt.parseInt(i64, (try ctx.getPara("user_type")) orelse "0", 10) catch 0,
        .type = (try ctx.getPara("type")) orelse "",
        .sub_type = (try ctx.getPara("sub_type")) orelse "",
        .biz_id = std.fmt.parseInt(i64, (try ctx.getPara("biz_id")) orelse "0", 10) catch 0,
        .action = (try ctx.getPara("action")) orelse "",
        .success = if ((try ctx.getPara("success"))) |v| (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "t")) else false,
        .extra = (try ctx.getPara("extra")) orelse "",
        .request_method = (try ctx.getPara("request_method")) orelse null,
        .request_url = (try ctx.getPara("request_url")) orelse null,
        .user_ip = (try ctx.getPara("user_ip")) orelse null,
        .user_agent = (try ctx.getPara("user_agent")) orelse null,
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

/// Update SystemOperateLog record (CSRF-protected).
pub fn update(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return failHttp(ctx, error.NotFound, "id");
    if (try ctx.getPara("trace_id")) |v| item.data.trace_id = v;
    if (try ctx.getPara("user_id")) |v| item.data.user_id = std.fmt.parseInt(i64, v, 10) catch item.data.user_id;
    if (try ctx.getPara("user_type")) |v| item.data.user_type = std.fmt.parseInt(i64, v, 10) catch item.data.user_type;
    if (try ctx.getPara("type")) |v| item.data.type = v;
    if (try ctx.getPara("sub_type")) |v| item.data.sub_type = v;
    if (try ctx.getPara("biz_id")) |v| item.data.biz_id = std.fmt.parseInt(i64, v, 10) catch item.data.biz_id;
    if (try ctx.getPara("action")) |v| item.data.action = v;
    if (try ctx.getPara("success")) |v| item.data.success = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("extra")) |v| item.data.extra = v;
    if (try ctx.getPara("request_method")) |v| item.data.request_method = v;
    if (try ctx.getPara("request_url")) |v| item.data.request_url = v;
    if (try ctx.getPara("user_ip")) |v| item.data.user_ip = v;
    if (try ctx.getPara("user_agent")) |v| item.data.user_agent = v;
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

/// Delete SystemOperateLog record (CSRF-protected).
pub fn delete(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return failHttp(ctx, error.NotFound, "id");
    try item.delete(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Partial update SystemOperateLog record (CSRF-protected, PATCH).
pub fn patch(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return failHttp(ctx, error.NotFound, "id");
    if (try ctx.getPara("trace_id")) |v| item.data.trace_id = v;
    if (try ctx.getPara("user_id")) |v| item.data.user_id = std.fmt.parseInt(i64, v, 10) catch item.data.user_id;
    if (try ctx.getPara("user_type")) |v| item.data.user_type = std.fmt.parseInt(i64, v, 10) catch item.data.user_type;
    if (try ctx.getPara("type")) |v| item.data.type = v;
    if (try ctx.getPara("sub_type")) |v| item.data.sub_type = v;
    if (try ctx.getPara("biz_id")) |v| item.data.biz_id = std.fmt.parseInt(i64, v, 10) catch item.data.biz_id;
    if (try ctx.getPara("action")) |v| item.data.action = v;
    if (try ctx.getPara("success")) |v| item.data.success = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("extra")) |v| item.data.extra = v;
    if (try ctx.getPara("request_method")) |v| item.data.request_method = v;
    if (try ctx.getPara("request_url")) |v| item.data.request_url = v;
    if (try ctx.getPara("user_ip")) |v| item.data.user_ip = v;
    if (try ctx.getPara("user_agent")) |v| item.data.user_agent = v;
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
