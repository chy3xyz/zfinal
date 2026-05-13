const std = @import("std");
const zfinal = @import("zfinal");
const PostsModel = @import("model.zig").PostsModel;
const validate = @import("model.zig").validate;
const pool_ref = &@import("../../deps.zig").pool;
const token_ref = &@import("../../deps.zig").tokenMgr;
const limit_ref = &@import("../../deps.zig").rateLimiter;

fn err(ctx: *zfinal.Context, status: std.http.Status, comptime msg: []const u8, code: i32) !void {
    ctx.res_status = status;
    try ctx.renderJson(.{ .err = msg, .code = code });
}

/// CSRF guard: validates csrf_token using TokenManager.
fn csrfGuard(ctx: *zfinal.Context) !void {
    const token = try ctx.getPara("csrf_token") orelse return err(ctx, .forbidden, "Missing CSRF token", 40301);
    if (!try token_ref.validate(token)) return err(ctx, .forbidden, "Invalid CSRF token", 40302);
}

/// List Posts records with pagination + rate limiting.
pub fn list(ctx: *zfinal.Context) !void {
    limit_ref.handle(ctx) catch {};
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    const page = try ctx.getParaToIntDefault("page", 1);
    const size = try ctx.getParaToIntDefault("size", 20);
    const items = try PostsModel.paginate(db, @intCast(page), @intCast(size), ctx.allocator);
    defer { for (items) |*it| it.deinit(ctx.allocator); ctx.allocator.free(items); }
    const total = try PostsModel.count(db);
    try ctx.renderJson(.{ .data = items, .total = total, .page = page, .size = size });
}

/// Show Posts by ID.
pub fn show(ctx: *zfinal.Context) !void {
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    const item = try PostsModel.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    defer item.deinit(ctx.allocator);
    try ctx.renderJson(.{ .data = item });
}

/// Create Posts record (CSRF-protected).
pub fn create(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var instance = PostsModel.Instance{
        .data = .{
            .id = std.fmt.parseInt(i64, (try ctx.getPara("id")) orelse "0", 10) catch 0,
            .title = (try ctx.getPara("title")) orelse "",
            .content = (try ctx.getPara("content")) orelse "",
            .author_id = std.fmt.parseInt(i64, (try ctx.getPara("author_id")) orelse "0", 10) catch 0,
            .published = if ((try ctx.getPara("published"))) |v| (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "t")) else null,
            .created_at = (try ctx.getPara("created_at")) orelse null,
        },
    };
    validate(instance.data) catch return err(ctx, .unprocessable_entity, "Validation failed", 42201);
    try instance.save(db);
    try ctx.renderJson(.{ .ok = true, .id = instance.id });
}

/// Update Posts record (CSRF-protected).
pub fn update(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try PostsModel.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    if (try ctx.getPara("title")) |v| item.data.title = v;
    if (try ctx.getPara("content")) |v| item.data.content = v;
    if (try ctx.getPara("author_id")) |v| item.data.author_id = std.fmt.parseInt(i64, v, 10) catch item.data.author_id;
    if (try ctx.getPara("published")) |v| item.data.published = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("created_at")) |v| item.data.created_at = v;
    validate(item.data) catch return err(ctx, .unprocessable_entity, "Validation failed", 42201);
    try item.save(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Delete Posts record (CSRF-protected).
pub fn delete(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try PostsModel.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    try item.delete(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Partial update Posts record (CSRF-protected, PATCH).
pub fn patch(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try PostsModel.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    if (try ctx.getPara("title")) |v| item.data.title = v;
    if (try ctx.getPara("content")) |v| item.data.content = v;
    if (try ctx.getPara("author_id")) |v| item.data.author_id = std.fmt.parseInt(i64, v, 10) catch item.data.author_id;
    if (try ctx.getPara("published")) |v| item.data.published = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("created_at")) |v| item.data.created_at = v;
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