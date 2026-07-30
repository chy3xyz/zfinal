// @generated — DO NOT EDIT. AI: edit ext/<name>.zig instead.
// Regenerate: zf crud:sql <schema.sql> — runs zf check after
const std = @import("std");
const zfinal = @import("zfinal");
const service = @import("service.gen.zig");
const pool = @import("../../../../../deps.zig").getPool();
const tokenMgr = @import("../../../../../deps.zig").getTokenMgr();
const rateLimiter = @import("../../../../../deps.zig").getRateLimiter();
fn failHttp(ctx: *zfinal.Context, http_err: anyerror, comptime detail: []const u8) anyerror {
    zfinal.http_error.setDetail(ctx, detail);
    return http_err;
}
fn err(ctx: *zfinal.Context, status: std.http.Status, comptime msg: []const u8, code: i32) !void {
    ctx.res_status = status;
    try ctx.renderJson(.{ .err = msg, .code = code });
}

/// CSRF guard: validates csrf_token using TokenManager.
fn csrfGuard(ctx: *zfinal.Context) !void {
    const token = try ctx.getPara("csrf_token") orelse return failHttp(ctx, error.Forbidden, "csrf_token");
    if (!try tokenMgr.validate(token)) return failHttp(ctx, error.Forbidden, "csrf_token");
}

/// List InfraApiErrorLog records with pagination + rate limiting.
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

/// Show InfraApiErrorLog by ID.
pub fn show(ctx: *zfinal.Context) !void {
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    const item = try service.findById(db, id, ctx.allocator) orelse return failHttp(ctx, error.NotFound, "id");
    defer item.deinit(ctx.allocator);
    try ctx.renderJson(.{ .data = item });
}

/// Create InfraApiErrorLog record (CSRF-protected).
pub fn create(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    const data: service.Data = .{
        .trace_id = (try ctx.getPara("trace_id")) orelse "",
        .user_id = std.fmt.parseInt(i64, (try ctx.getPara("user_id")) orelse "0", 10) catch 0,
        .user_type = std.fmt.parseInt(i64, (try ctx.getPara("user_type")) orelse "0", 10) catch 0,
        .application_name = (try ctx.getPara("application_name")) orelse "",
        .request_method = (try ctx.getPara("request_method")) orelse "",
        .request_url = (try ctx.getPara("request_url")) orelse "",
        .request_params = (try ctx.getPara("request_params")) orelse "",
        .user_ip = (try ctx.getPara("user_ip")) orelse "",
        .user_agent = (try ctx.getPara("user_agent")) orelse "",
        .exception_time = (try ctx.getPara("exception_time")) orelse "",
        .exception_name = (try ctx.getPara("exception_name")) orelse "",
        .exception_message = (try ctx.getPara("exception_message")) orelse "",
        .exception_root_cause_message = (try ctx.getPara("exception_root_cause_message")) orelse "",
        .exception_stack_trace = (try ctx.getPara("exception_stack_trace")) orelse "",
        .exception_class_name = (try ctx.getPara("exception_class_name")) orelse "",
        .exception_file_name = (try ctx.getPara("exception_file_name")) orelse "",
        .exception_method_name = (try ctx.getPara("exception_method_name")) orelse "",
        .exception_line_number = std.fmt.parseInt(i64, (try ctx.getPara("exception_line_number")) orelse "0", 10) catch 0,
        .process_status = std.fmt.parseInt(i64, (try ctx.getPara("process_status")) orelse "0", 10) catch 0,
        .process_time = (try ctx.getPara("process_time")) orelse null,
        .process_user_id = std.fmt.parseInt(i64, (try ctx.getPara("process_user_id")) orelse "0", 10) catch 0,
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

/// Update InfraApiErrorLog record (CSRF-protected).
pub fn update(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return failHttp(ctx, error.NotFound, "id");
    if (try ctx.getPara("trace_id")) |v| item.data.trace_id = v;
    if (try ctx.getPara("user_id")) |v| item.data.user_id = std.fmt.parseInt(i64, v, 10) catch item.data.user_id;
    if (try ctx.getPara("user_type")) |v| item.data.user_type = std.fmt.parseInt(i64, v, 10) catch item.data.user_type;
    if (try ctx.getPara("application_name")) |v| item.data.application_name = v;
    if (try ctx.getPara("request_method")) |v| item.data.request_method = v;
    if (try ctx.getPara("request_url")) |v| item.data.request_url = v;
    if (try ctx.getPara("request_params")) |v| item.data.request_params = v;
    if (try ctx.getPara("user_ip")) |v| item.data.user_ip = v;
    if (try ctx.getPara("user_agent")) |v| item.data.user_agent = v;
    if (try ctx.getPara("exception_time")) |v| item.data.exception_time = v;
    if (try ctx.getPara("exception_name")) |v| item.data.exception_name = v;
    if (try ctx.getPara("exception_message")) |v| item.data.exception_message = v;
    if (try ctx.getPara("exception_root_cause_message")) |v| item.data.exception_root_cause_message = v;
    if (try ctx.getPara("exception_stack_trace")) |v| item.data.exception_stack_trace = v;
    if (try ctx.getPara("exception_class_name")) |v| item.data.exception_class_name = v;
    if (try ctx.getPara("exception_file_name")) |v| item.data.exception_file_name = v;
    if (try ctx.getPara("exception_method_name")) |v| item.data.exception_method_name = v;
    if (try ctx.getPara("exception_line_number")) |v| item.data.exception_line_number = std.fmt.parseInt(i64, v, 10) catch item.data.exception_line_number;
    if (try ctx.getPara("process_status")) |v| item.data.process_status = std.fmt.parseInt(i64, v, 10) catch item.data.process_status;
    if (try ctx.getPara("process_time")) |v| item.data.process_time = v;
    if (try ctx.getPara("process_user_id")) |v| item.data.process_user_id = std.fmt.parseInt(i64, v, 10) catch item.data.process_user_id;
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

/// Delete InfraApiErrorLog record (CSRF-protected).
pub fn delete(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return failHttp(ctx, error.NotFound, "id");
    try item.delete(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Partial update InfraApiErrorLog record (CSRF-protected, PATCH).
pub fn patch(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    var item = try service.findById(db, id, ctx.allocator) orelse return failHttp(ctx, error.NotFound, "id");
    if (try ctx.getPara("trace_id")) |v| item.data.trace_id = v;
    if (try ctx.getPara("user_id")) |v| item.data.user_id = std.fmt.parseInt(i64, v, 10) catch item.data.user_id;
    if (try ctx.getPara("user_type")) |v| item.data.user_type = std.fmt.parseInt(i64, v, 10) catch item.data.user_type;
    if (try ctx.getPara("application_name")) |v| item.data.application_name = v;
    if (try ctx.getPara("request_method")) |v| item.data.request_method = v;
    if (try ctx.getPara("request_url")) |v| item.data.request_url = v;
    if (try ctx.getPara("request_params")) |v| item.data.request_params = v;
    if (try ctx.getPara("user_ip")) |v| item.data.user_ip = v;
    if (try ctx.getPara("user_agent")) |v| item.data.user_agent = v;
    if (try ctx.getPara("exception_time")) |v| item.data.exception_time = v;
    if (try ctx.getPara("exception_name")) |v| item.data.exception_name = v;
    if (try ctx.getPara("exception_message")) |v| item.data.exception_message = v;
    if (try ctx.getPara("exception_root_cause_message")) |v| item.data.exception_root_cause_message = v;
    if (try ctx.getPara("exception_stack_trace")) |v| item.data.exception_stack_trace = v;
    if (try ctx.getPara("exception_class_name")) |v| item.data.exception_class_name = v;
    if (try ctx.getPara("exception_file_name")) |v| item.data.exception_file_name = v;
    if (try ctx.getPara("exception_method_name")) |v| item.data.exception_method_name = v;
    if (try ctx.getPara("exception_line_number")) |v| item.data.exception_line_number = std.fmt.parseInt(i64, v, 10) catch item.data.exception_line_number;
    if (try ctx.getPara("process_status")) |v| item.data.process_status = std.fmt.parseInt(i64, v, 10) catch item.data.process_status;
    if (try ctx.getPara("process_time")) |v| item.data.process_time = v;
    if (try ctx.getPara("process_user_id")) |v| item.data.process_user_id = std.fmt.parseInt(i64, v, 10) catch item.data.process_user_id;
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
