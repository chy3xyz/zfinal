// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");
const service = @import("service.gen.zig");
const pool_ref = &@import("../../../deps.zig").pool;
const token_ref = &@import("../../../deps.zig").tokenMgr;
const limit_ref = &@import("../../../deps.zig").rateLimiter;

fn err(ctx: *zfinal.Context, status: std.http.Status, comptime msg: []const u8, code: i32) !void {
    ctx.res_status = status;
    try ctx.renderJson(.{ .err = msg, .code = code });
}

/// CSRF guard: validates csrf_token using TokenManager.
fn csrfGuard(ctx: *zfinal.Context) !void {
    const token = try ctx.getPara("csrf_token") orelse return err(ctx, .forbidden, "Missing CSRF token", 40301);
    if (!try token_ref.validate(token)) return err(ctx, .forbidden, "Invalid CSRF token", 40302);
}

/// List SystemRole records with pagination + rate limiting.
pub fn list(ctx: *zfinal.Context) !void {
    limit_ref.handle(ctx) catch {};
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    const page = try ctx.getParaToIntDefault("page", 1);
    const size = try ctx.getParaToIntDefault("size", 20);
    const items = try service.paginate(db, @intCast(page), @intCast(size), ctx.allocator);
    defer { for (items) |*it| it.deinit(ctx.allocator); ctx.allocator.free(items); }
    const total = try service.count(db);
    try ctx.renderJson(.{ .data = items, .total = total, .page = page, .size = size });
}

/// Show SystemRole by ID.
pub fn show(ctx: *zfinal.Context) !void {
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    const item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    defer item.deinit(ctx.allocator);
    try ctx.renderJson(.{ .data = item });
}

/// Create SystemRole record (CSRF-protected).
pub fn create(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    const data: service.Data = .{
            .name = (try ctx.getPara("name")) orelse "",
            .code = (try ctx.getPara("code")) orelse "",
            .sort = std.fmt.parseInt(i64, (try ctx.getPara("sort")) orelse "0", 10) catch 0,
            .data_scope = std.fmt.parseInt(i64, (try ctx.getPara("data_scope")) orelse "0", 10) catch 0,
            .data_scope_dept_ids = (try ctx.getPara("data_scope_dept_ids")) orelse "",
    };
    const instance = service.create(db, data) catch |e| {
        if (e == error.ValidationError) return err(ctx, .unprocessable_entity, "Validation failed", 42201);
        return e;
    };
    try ctx.renderJson(.{ .ok = true, .id = instance.id });
}

/// Update SystemRole record (CSRF-protected).
pub fn update(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    if (try ctx.getPara("name")) |v| item.data.name = v;
    if (try ctx.getPara("code")) |v| item.data.code = v;
    if (try ctx.getPara("sort")) |v| item.data.sort = std.fmt.parseInt(i64, v, 10) catch item.data.sort;
    if (try ctx.getPara("data_scope")) |v| item.data.data_scope = std.fmt.parseInt(i64, v, 10) catch item.data.data_scope;
    if (try ctx.getPara("data_scope_dept_ids")) |v| item.data.data_scope_dept_ids = v;
    // Validation handled by service layer
    try item.save(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Delete SystemRole record (CSRF-protected).
pub fn delete(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    try item.delete(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Partial update SystemRole record (CSRF-protected, PATCH).
pub fn patch(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    if (try ctx.getPara("name")) |v| item.data.name = v;
    if (try ctx.getPara("code")) |v| item.data.code = v;
    if (try ctx.getPara("sort")) |v| item.data.sort = std.fmt.parseInt(i64, v, 10) catch item.data.sort;
    if (try ctx.getPara("data_scope")) |v| item.data.data_scope = std.fmt.parseInt(i64, v, 10) catch item.data.data_scope;
    if (try ctx.getPara("data_scope_dept_ids")) |v| item.data.data_scope_dept_ids = v;
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