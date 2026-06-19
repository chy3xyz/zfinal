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

/// List SystemDictData records with pagination + rate limiting.
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

/// Show SystemDictData by ID.
pub fn show(ctx: *zfinal.Context) !void {
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    const item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    defer item.deinit(ctx.allocator);
    try ctx.renderJson(.{ .data = item });
}

/// Create SystemDictData record (CSRF-protected).
pub fn create(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    const data: service.Data = .{
        .sort = std.fmt.parseInt(i64, (try ctx.getPara("sort")) orelse "0", 10) catch 0,
        .label = (try ctx.getPara("label")) orelse "",
        .value = (try ctx.getPara("value")) orelse "",
        .dict_type = (try ctx.getPara("dict_type")) orelse "",
        .status = std.fmt.parseInt(i64, (try ctx.getPara("status")) orelse "0", 10) catch 0,
        .color_type = (try ctx.getPara("color_type")) orelse null,
        .css_class = (try ctx.getPara("css_class")) orelse null,
        .remark = (try ctx.getPara("remark")) orelse null,
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

/// Update SystemDictData record (CSRF-protected).
pub fn update(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    if (try ctx.getPara("sort")) |v| item.data.sort = std.fmt.parseInt(i64, v, 10) catch item.data.sort;
    if (try ctx.getPara("label")) |v| item.data.label = v;
    if (try ctx.getPara("value")) |v| item.data.value = v;
    if (try ctx.getPara("dict_type")) |v| item.data.dict_type = v;
    if (try ctx.getPara("status")) |v| item.data.status = std.fmt.parseInt(i64, v, 10) catch item.data.status;
    if (try ctx.getPara("color_type")) |v| item.data.color_type = v;
    if (try ctx.getPara("css_class")) |v| item.data.css_class = v;
    if (try ctx.getPara("remark")) |v| item.data.remark = v;
    if (try ctx.getPara("creator")) |v| item.data.creator = v;
    if (try ctx.getPara("create_time")) |v| item.data.create_time = v;
    if (try ctx.getPara("updater")) |v| item.data.updater = v;
    if (try ctx.getPara("update_time")) |v| item.data.update_time = v;
    if (try ctx.getPara("deleted")) |v| item.data.deleted = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    // Validation handled by service layer
    try item.save(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Delete SystemDictData record (CSRF-protected).
pub fn delete(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    try item.delete(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Partial update SystemDictData record (CSRF-protected, PATCH).
pub fn patch(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    if (try ctx.getPara("sort")) |v| item.data.sort = std.fmt.parseInt(i64, v, 10) catch item.data.sort;
    if (try ctx.getPara("label")) |v| item.data.label = v;
    if (try ctx.getPara("value")) |v| item.data.value = v;
    if (try ctx.getPara("dict_type")) |v| item.data.dict_type = v;
    if (try ctx.getPara("status")) |v| item.data.status = std.fmt.parseInt(i64, v, 10) catch item.data.status;
    if (try ctx.getPara("color_type")) |v| item.data.color_type = v;
    if (try ctx.getPara("css_class")) |v| item.data.css_class = v;
    if (try ctx.getPara("remark")) |v| item.data.remark = v;
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
