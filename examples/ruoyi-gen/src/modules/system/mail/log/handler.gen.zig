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

/// List SystemMailLog records with pagination + rate limiting.
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

/// Show SystemMailLog by ID.
pub fn show(ctx: *zfinal.Context) !void {
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    const item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    defer item.deinit(ctx.allocator);
    try ctx.renderJson(.{ .data = item });
}

/// Create SystemMailLog record (CSRF-protected).
pub fn create(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    const data: service.Data = .{
            .user_id = std.fmt.parseInt(i64, (try ctx.getPara("user_id")) orelse "0", 10) catch 0,
            .user_type = std.fmt.parseInt(i64, (try ctx.getPara("user_type")) orelse "0", 10) catch 0,
            .to_mails = (try ctx.getPara("to_mails")) orelse "",
            .cc_mails = (try ctx.getPara("cc_mails")) orelse null,
            .bcc_mails = (try ctx.getPara("bcc_mails")) orelse null,
            .account_id = std.fmt.parseInt(i64, (try ctx.getPara("account_id")) orelse "0", 10) catch 0,
            .from_mail = (try ctx.getPara("from_mail")) orelse "",
            .template_id = std.fmt.parseInt(i64, (try ctx.getPara("template_id")) orelse "0", 10) catch 0,
            .template_code = (try ctx.getPara("template_code")) orelse "",
            .template_nickname = (try ctx.getPara("template_nickname")) orelse null,
            .template_title = (try ctx.getPara("template_title")) orelse "",
            .template_content = (try ctx.getPara("template_content")) orelse "",
            .template_params = (try ctx.getPara("template_params")) orelse "",
            .send_status = std.fmt.parseInt(i64, (try ctx.getPara("send_status")) orelse "0", 10) catch 0,
            .send_time = (try ctx.getPara("send_time")) orelse null,
            .send_message_id = (try ctx.getPara("send_message_id")) orelse null,
            .send_exception = (try ctx.getPara("send_exception")) orelse null,
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

/// Update SystemMailLog record (CSRF-protected).
pub fn update(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    if (try ctx.getPara("user_id")) |v| item.data.user_id = std.fmt.parseInt(i64, v, 10) catch item.data.user_id;
    if (try ctx.getPara("user_type")) |v| item.data.user_type = std.fmt.parseInt(i64, v, 10) catch item.data.user_type;
    if (try ctx.getPara("to_mails")) |v| item.data.to_mails = v;
    if (try ctx.getPara("cc_mails")) |v| item.data.cc_mails = v;
    if (try ctx.getPara("bcc_mails")) |v| item.data.bcc_mails = v;
    if (try ctx.getPara("account_id")) |v| item.data.account_id = std.fmt.parseInt(i64, v, 10) catch item.data.account_id;
    if (try ctx.getPara("from_mail")) |v| item.data.from_mail = v;
    if (try ctx.getPara("template_id")) |v| item.data.template_id = std.fmt.parseInt(i64, v, 10) catch item.data.template_id;
    if (try ctx.getPara("template_code")) |v| item.data.template_code = v;
    if (try ctx.getPara("template_nickname")) |v| item.data.template_nickname = v;
    if (try ctx.getPara("template_title")) |v| item.data.template_title = v;
    if (try ctx.getPara("template_content")) |v| item.data.template_content = v;
    if (try ctx.getPara("template_params")) |v| item.data.template_params = v;
    if (try ctx.getPara("send_status")) |v| item.data.send_status = std.fmt.parseInt(i64, v, 10) catch item.data.send_status;
    if (try ctx.getPara("send_time")) |v| item.data.send_time = v;
    if (try ctx.getPara("send_message_id")) |v| item.data.send_message_id = v;
    if (try ctx.getPara("send_exception")) |v| item.data.send_exception = v;
    if (try ctx.getPara("creator")) |v| item.data.creator = v;
    if (try ctx.getPara("create_time")) |v| item.data.create_time = v;
    if (try ctx.getPara("updater")) |v| item.data.updater = v;
    if (try ctx.getPara("update_time")) |v| item.data.update_time = v;
    if (try ctx.getPara("deleted")) |v| item.data.deleted = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    // Validation handled by service layer
    try item.save(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Delete SystemMailLog record (CSRF-protected).
pub fn delete(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    try item.delete(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Partial update SystemMailLog record (CSRF-protected, PATCH).
pub fn patch(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    if (try ctx.getPara("user_id")) |v| item.data.user_id = std.fmt.parseInt(i64, v, 10) catch item.data.user_id;
    if (try ctx.getPara("user_type")) |v| item.data.user_type = std.fmt.parseInt(i64, v, 10) catch item.data.user_type;
    if (try ctx.getPara("to_mails")) |v| item.data.to_mails = v;
    if (try ctx.getPara("cc_mails")) |v| item.data.cc_mails = v;
    if (try ctx.getPara("bcc_mails")) |v| item.data.bcc_mails = v;
    if (try ctx.getPara("account_id")) |v| item.data.account_id = std.fmt.parseInt(i64, v, 10) catch item.data.account_id;
    if (try ctx.getPara("from_mail")) |v| item.data.from_mail = v;
    if (try ctx.getPara("template_id")) |v| item.data.template_id = std.fmt.parseInt(i64, v, 10) catch item.data.template_id;
    if (try ctx.getPara("template_code")) |v| item.data.template_code = v;
    if (try ctx.getPara("template_nickname")) |v| item.data.template_nickname = v;
    if (try ctx.getPara("template_title")) |v| item.data.template_title = v;
    if (try ctx.getPara("template_content")) |v| item.data.template_content = v;
    if (try ctx.getPara("template_params")) |v| item.data.template_params = v;
    if (try ctx.getPara("send_status")) |v| item.data.send_status = std.fmt.parseInt(i64, v, 10) catch item.data.send_status;
    if (try ctx.getPara("send_time")) |v| item.data.send_time = v;
    if (try ctx.getPara("send_message_id")) |v| item.data.send_message_id = v;
    if (try ctx.getPara("send_exception")) |v| item.data.send_exception = v;
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