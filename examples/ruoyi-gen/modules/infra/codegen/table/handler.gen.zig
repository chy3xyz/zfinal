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

/// List InfraCodegenTable records with pagination + rate limiting.
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

/// Show InfraCodegenTable by ID.
pub fn show(ctx: *zfinal.Context) !void {
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    const item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    defer item.deinit(ctx.allocator);
    try ctx.renderJson(.{ .data = item });
}

/// Create InfraCodegenTable record (CSRF-protected).
pub fn create(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    const data: service.Data = .{
        .data_source_config_id = std.fmt.parseInt(i64, (try ctx.getPara("data_source_config_id")) orelse "0", 10) catch 0,
        .scene = std.fmt.parseInt(i64, (try ctx.getPara("scene")) orelse "0", 10) catch 0,
        .table_name = (try ctx.getPara("table_name")) orelse "",
        .table_comment = (try ctx.getPara("table_comment")) orelse "",
        .remark = (try ctx.getPara("remark")) orelse null,
        .module_name = (try ctx.getPara("module_name")) orelse "",
        .business_name = (try ctx.getPara("business_name")) orelse "",
        .class_name = (try ctx.getPara("class_name")) orelse "",
        .class_comment = (try ctx.getPara("class_comment")) orelse "",
        .author = (try ctx.getPara("author")) orelse "",
        .template_type = std.fmt.parseInt(i64, (try ctx.getPara("template_type")) orelse "0", 10) catch 0,
        .front_type = std.fmt.parseInt(i64, (try ctx.getPara("front_type")) orelse "0", 10) catch 0,
        .parent_menu_id = std.fmt.parseInt(i64, (try ctx.getPara("parent_menu_id")) orelse "0", 10) catch 0,
        .master_table_id = std.fmt.parseInt(i64, (try ctx.getPara("master_table_id")) orelse "0", 10) catch 0,
        .sub_join_column_id = std.fmt.parseInt(i64, (try ctx.getPara("sub_join_column_id")) orelse "0", 10) catch 0,
        .sub_join_many = if ((try ctx.getPara("sub_join_many"))) |v| (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "t")) else null,
        .tree_parent_column_id = std.fmt.parseInt(i64, (try ctx.getPara("tree_parent_column_id")) orelse "0", 10) catch 0,
        .tree_name_column_id = std.fmt.parseInt(i64, (try ctx.getPara("tree_name_column_id")) orelse "0", 10) catch 0,
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

/// Update InfraCodegenTable record (CSRF-protected).
pub fn update(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    if (try ctx.getPara("data_source_config_id")) |v| item.data.data_source_config_id = std.fmt.parseInt(i64, v, 10) catch item.data.data_source_config_id;
    if (try ctx.getPara("scene")) |v| item.data.scene = std.fmt.parseInt(i64, v, 10) catch item.data.scene;
    if (try ctx.getPara("table_name")) |v| item.data.table_name = v;
    if (try ctx.getPara("table_comment")) |v| item.data.table_comment = v;
    if (try ctx.getPara("remark")) |v| item.data.remark = v;
    if (try ctx.getPara("module_name")) |v| item.data.module_name = v;
    if (try ctx.getPara("business_name")) |v| item.data.business_name = v;
    if (try ctx.getPara("class_name")) |v| item.data.class_name = v;
    if (try ctx.getPara("class_comment")) |v| item.data.class_comment = v;
    if (try ctx.getPara("author")) |v| item.data.author = v;
    if (try ctx.getPara("template_type")) |v| item.data.template_type = std.fmt.parseInt(i64, v, 10) catch item.data.template_type;
    if (try ctx.getPara("front_type")) |v| item.data.front_type = std.fmt.parseInt(i64, v, 10) catch item.data.front_type;
    if (try ctx.getPara("parent_menu_id")) |v| item.data.parent_menu_id = std.fmt.parseInt(i64, v, 10) catch item.data.parent_menu_id;
    if (try ctx.getPara("master_table_id")) |v| item.data.master_table_id = std.fmt.parseInt(i64, v, 10) catch item.data.master_table_id;
    if (try ctx.getPara("sub_join_column_id")) |v| item.data.sub_join_column_id = std.fmt.parseInt(i64, v, 10) catch item.data.sub_join_column_id;
    if (try ctx.getPara("sub_join_many")) |v| item.data.sub_join_many = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("tree_parent_column_id")) |v| item.data.tree_parent_column_id = std.fmt.parseInt(i64, v, 10) catch item.data.tree_parent_column_id;
    if (try ctx.getPara("tree_name_column_id")) |v| item.data.tree_name_column_id = std.fmt.parseInt(i64, v, 10) catch item.data.tree_name_column_id;
    if (try ctx.getPara("creator")) |v| item.data.creator = v;
    if (try ctx.getPara("create_time")) |v| item.data.create_time = v;
    if (try ctx.getPara("updater")) |v| item.data.updater = v;
    if (try ctx.getPara("update_time")) |v| item.data.update_time = v;
    if (try ctx.getPara("deleted")) |v| item.data.deleted = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    // Validation handled by service layer
    try item.save(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Delete InfraCodegenTable record (CSRF-protected).
pub fn delete(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    try item.delete(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Partial update InfraCodegenTable record (CSRF-protected, PATCH).
pub fn patch(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return err(ctx, .not_found, "Not found", 40401);
    if (try ctx.getPara("data_source_config_id")) |v| item.data.data_source_config_id = std.fmt.parseInt(i64, v, 10) catch item.data.data_source_config_id;
    if (try ctx.getPara("scene")) |v| item.data.scene = std.fmt.parseInt(i64, v, 10) catch item.data.scene;
    if (try ctx.getPara("table_name")) |v| item.data.table_name = v;
    if (try ctx.getPara("table_comment")) |v| item.data.table_comment = v;
    if (try ctx.getPara("remark")) |v| item.data.remark = v;
    if (try ctx.getPara("module_name")) |v| item.data.module_name = v;
    if (try ctx.getPara("business_name")) |v| item.data.business_name = v;
    if (try ctx.getPara("class_name")) |v| item.data.class_name = v;
    if (try ctx.getPara("class_comment")) |v| item.data.class_comment = v;
    if (try ctx.getPara("author")) |v| item.data.author = v;
    if (try ctx.getPara("template_type")) |v| item.data.template_type = std.fmt.parseInt(i64, v, 10) catch item.data.template_type;
    if (try ctx.getPara("front_type")) |v| item.data.front_type = std.fmt.parseInt(i64, v, 10) catch item.data.front_type;
    if (try ctx.getPara("parent_menu_id")) |v| item.data.parent_menu_id = std.fmt.parseInt(i64, v, 10) catch item.data.parent_menu_id;
    if (try ctx.getPara("master_table_id")) |v| item.data.master_table_id = std.fmt.parseInt(i64, v, 10) catch item.data.master_table_id;
    if (try ctx.getPara("sub_join_column_id")) |v| item.data.sub_join_column_id = std.fmt.parseInt(i64, v, 10) catch item.data.sub_join_column_id;
    if (try ctx.getPara("sub_join_many")) |v| item.data.sub_join_many = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (try ctx.getPara("tree_parent_column_id")) |v| item.data.tree_parent_column_id = std.fmt.parseInt(i64, v, 10) catch item.data.tree_parent_column_id;
    if (try ctx.getPara("tree_name_column_id")) |v| item.data.tree_name_column_id = std.fmt.parseInt(i64, v, 10) catch item.data.tree_name_column_id;
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
