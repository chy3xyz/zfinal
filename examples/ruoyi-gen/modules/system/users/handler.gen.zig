// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");
const service = @import("service.gen.zig");
const pool_ref = &@import("../../../deps.zig").pool;
const token_ref = &@import("../../../deps.zig").tokenMgr;
const limit_ref = &@import("../../../deps.zig").rateLimiter;

fn failHttp(ctx: *zfinal.Context, http_err: anyerror, comptime detail: []const u8) anyerror {
    zfinal.http_error.setDetail(ctx, detail);
    return http_err;
}

/// CSRF guard: validates csrf_token using TokenManager.
fn csrfGuard(ctx: *zfinal.Context) !void {
    const token = try ctx.getPara("csrf_token") orelse return failHttp(ctx, error.Forbidden, "csrf_token");
    if (!try token_ref.validate(token)) return failHttp(ctx, error.Forbidden, "csrf_token");
}

/// List SystemUsers records with pagination + rate limiting.
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

/// Show SystemUsers by ID.
pub fn show(ctx: *zfinal.Context) !void {
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    const item = try service.findById(db, id, ctx.allocator) orelse return failHttp(ctx, error.NotFound, "id");
    defer item.deinit(ctx.allocator);
    try ctx.renderJson(.{ .data = item });
}

/// Create SystemUsers record (CSRF-protected).
pub fn create(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    const data: service.Data = .{
        .username = (try ctx.getPara("username")) orelse "",
        .password = (try ctx.getPara("password")) orelse "",
        .nickname = (try ctx.getPara("nickname")) orelse "",
        .remark = (try ctx.getPara("remark")) orelse null,
        .dept_id = std.fmt.parseInt(i64, (try ctx.getPara("dept_id")) orelse "0", 10) catch 0,
        .post_ids = (try ctx.getPara("post_ids")) orelse null,
        .email = (try ctx.getPara("email")) orelse null,
        .mobile = (try ctx.getPara("mobile")) orelse null,
        .sex = std.fmt.parseInt(i64, (try ctx.getPara("sex")) orelse "0", 10) catch 0,
        .avatar = (try ctx.getPara("avatar")) orelse null,
        .status = std.fmt.parseInt(i64, (try ctx.getPara("status")) orelse "0", 10) catch 0,
        .login_ip = (try ctx.getPara("login_ip")) orelse null,
        .login_date = (try ctx.getPara("login_date")) orelse null,
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

/// Update SystemUsers record (CSRF-protected).
pub fn update(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return failHttp(ctx, error.NotFound, "id");
    if (try ctx.getPara("username")) |v| item.data.username = v;
    if (try ctx.getPara("password")) |v| item.data.password = v;
    if (try ctx.getPara("nickname")) |v| item.data.nickname = v;
    if (try ctx.getPara("remark")) |v| item.data.remark = v;
    if (try ctx.getPara("dept_id")) |v| item.data.dept_id = std.fmt.parseInt(i64, v, 10) catch item.data.dept_id;
    if (try ctx.getPara("post_ids")) |v| item.data.post_ids = v;
    if (try ctx.getPara("email")) |v| item.data.email = v;
    if (try ctx.getPara("mobile")) |v| item.data.mobile = v;
    if (try ctx.getPara("sex")) |v| item.data.sex = std.fmt.parseInt(i64, v, 10) catch item.data.sex;
    if (try ctx.getPara("avatar")) |v| item.data.avatar = v;
    if (try ctx.getPara("status")) |v| item.data.status = std.fmt.parseInt(i64, v, 10) catch item.data.status;
    if (try ctx.getPara("login_ip")) |v| item.data.login_ip = v;
    if (try ctx.getPara("login_date")) |v| item.data.login_date = v;
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

/// Delete SystemUsers record (CSRF-protected).
pub fn delete(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return failHttp(ctx, error.NotFound, "id");
    try item.delete(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Partial update SystemUsers record (CSRF-protected, PATCH).
pub fn patch(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return failHttp(ctx, error.NotFound, "id");
    if (try ctx.getPara("username")) |v| item.data.username = v;
    if (try ctx.getPara("password")) |v| item.data.password = v;
    if (try ctx.getPara("nickname")) |v| item.data.nickname = v;
    if (try ctx.getPara("remark")) |v| item.data.remark = v;
    if (try ctx.getPara("dept_id")) |v| item.data.dept_id = std.fmt.parseInt(i64, v, 10) catch item.data.dept_id;
    if (try ctx.getPara("post_ids")) |v| item.data.post_ids = v;
    if (try ctx.getPara("email")) |v| item.data.email = v;
    if (try ctx.getPara("mobile")) |v| item.data.mobile = v;
    if (try ctx.getPara("sex")) |v| item.data.sex = std.fmt.parseInt(i64, v, 10) catch item.data.sex;
    if (try ctx.getPara("avatar")) |v| item.data.avatar = v;
    if (try ctx.getPara("status")) |v| item.data.status = std.fmt.parseInt(i64, v, 10) catch item.data.status;
    if (try ctx.getPara("login_ip")) |v| item.data.login_ip = v;
    if (try ctx.getPara("login_date")) |v| item.data.login_date = v;
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
