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

/// List InfraCodegenColumn records with pagination + rate limiting.
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

/// Show InfraCodegenColumn by ID.
pub fn show(ctx: *zfinal.Context) !void {
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    const item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    defer item.deinit(ctx.allocator);
    try ctx.renderJson(.{ .data = item });
}

/// Create InfraCodegenColumn record (CSRF-protected).
pub fn create(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    const data: service.Data = .{
            .table_id = std.fmt.parseInt(i64, (try ctx.getPara("table_id")) orelse "0", 10) catch 0,
            .column_name = (try ctx.getPara("column_name")) orelse "",
            .data_type = (try ctx.getPara("data_type")) orelse "",
            .column_comment = (try ctx.getPara("column_comment")) orelse "",
            .nullable = if ((try ctx.getPara("nullable"))) |v| (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "t")) else false,
            .primary_key = if ((try ctx.getPara("primary_key"))) |v| (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "t")) else false,
            .ordinal_position = std.fmt.parseInt(i64, (try ctx.getPara("ordinal_position")) orelse "0", 10) catch 0,
            .java_type = (try ctx.getPara("java_type")) orelse "",
            .java_field = (try ctx.getPara("java_field")) orelse "",
            .dict_type = (try ctx.getPara("dict_type")) orelse null,
            .example = (try ctx.getPara("example")) orelse null,
            .create_operation = if ((try ctx.getPara("create_operation"))) |v| (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "t")) else false,
            .update_operation = if ((try ctx.getPara("update_operation"))) |v| (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "t")) else false,
            .list_operation = if ((try ctx.getPara("list_operation"))) |v| (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "t")) else false,
            .list_operation_condition = (try ctx.getPara("list_operation_condition")) orelse "",
            .list_operation_result = if ((try ctx.getPara("list_operation_result"))) |v| (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "t")) else false,
            .html_type = (try ctx.getPara("html_type")) orelse "",
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

/// Update InfraCodegenColumn record (CSRF-protected).
pub fn update(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    if (try ctx.getPara("table_id")) |v| item.data.table_id = std.fmt.parseInt(i64, v, 10) catch item.data.table_id;
    if (try ctx.getPara("column_name")) |v| item.data.column_name = v;
    if (try ctx.getPara("data_type")) |v| item.data.data_type = v;
    if (try ctx.getPara("column_comment")) |v| item.data.column_comment = v;
    if (try ctx.getPara("nullable")) |v| item.data.nullable = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("primary_key")) |v| item.data.primary_key = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("ordinal_position")) |v| item.data.ordinal_position = std.fmt.parseInt(i64, v, 10) catch item.data.ordinal_position;
    if (try ctx.getPara("java_type")) |v| item.data.java_type = v;
    if (try ctx.getPara("java_field")) |v| item.data.java_field = v;
    if (try ctx.getPara("dict_type")) |v| item.data.dict_type = v;
    if (try ctx.getPara("example")) |v| item.data.example = v;
    if (try ctx.getPara("create_operation")) |v| item.data.create_operation = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("update_operation")) |v| item.data.update_operation = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("list_operation")) |v| item.data.list_operation = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("list_operation_condition")) |v| item.data.list_operation_condition = v;
    if (try ctx.getPara("list_operation_result")) |v| item.data.list_operation_result = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("html_type")) |v| item.data.html_type = v;
    if (try ctx.getPara("creator")) |v| item.data.creator = v;
    if (try ctx.getPara("create_time")) |v| item.data.create_time = v;
    if (try ctx.getPara("updater")) |v| item.data.updater = v;
    if (try ctx.getPara("update_time")) |v| item.data.update_time = v;
    if (try ctx.getPara("deleted")) |v| item.data.deleted = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    // Validation handled by service layer
    try item.save(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Delete InfraCodegenColumn record (CSRF-protected).
pub fn delete(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    try item.delete(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Partial update InfraCodegenColumn record (CSRF-protected, PATCH).
pub fn patch(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    if (try ctx.getPara("table_id")) |v| item.data.table_id = std.fmt.parseInt(i64, v, 10) catch item.data.table_id;
    if (try ctx.getPara("column_name")) |v| item.data.column_name = v;
    if (try ctx.getPara("data_type")) |v| item.data.data_type = v;
    if (try ctx.getPara("column_comment")) |v| item.data.column_comment = v;
    if (try ctx.getPara("nullable")) |v| item.data.nullable = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("primary_key")) |v| item.data.primary_key = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("ordinal_position")) |v| item.data.ordinal_position = std.fmt.parseInt(i64, v, 10) catch item.data.ordinal_position;
    if (try ctx.getPara("java_type")) |v| item.data.java_type = v;
    if (try ctx.getPara("java_field")) |v| item.data.java_field = v;
    if (try ctx.getPara("dict_type")) |v| item.data.dict_type = v;
    if (try ctx.getPara("example")) |v| item.data.example = v;
    if (try ctx.getPara("create_operation")) |v| item.data.create_operation = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("update_operation")) |v| item.data.update_operation = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("list_operation")) |v| item.data.list_operation = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("list_operation_condition")) |v| item.data.list_operation_condition = v;
    if (try ctx.getPara("list_operation_result")) |v| item.data.list_operation_result = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("html_type")) |v| item.data.html_type = v;
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