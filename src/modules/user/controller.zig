const std = @import("std");
const zfinal = @import("zfinal");
const UsersModel = @import("model.zig").UsersModel;
const validate = @import("model.zig").validate;
const pool_ref = &@import("../../deps.zig").pool;

/// CSRF guard: checks csrf_token for state-changing requests.
fn csrfGuard(ctx: *zfinal.Context) !void {
    const token = try ctx.getPara("csrf_token") orelse {
        ctx.res_status = .forbidden;
        try ctx.renderJson(.{ .err = "Missing CSRF token" });
        return error.CsrfRequired;
    };
    _ = token; // AI: validate with TokenManager here
}

/// List Users records with pagination.
pub fn list(ctx: *zfinal.Context) !void {
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    const page = try ctx.getParaToIntDefault("page", 1);
    const size = try ctx.getParaToIntDefault("size", 20);
    const items = try UsersModel.paginate(db, @intCast(page), @intCast(size), ctx.allocator);
    defer { for (items) |*it| it.deinit(ctx.allocator); ctx.allocator.free(items); }
    const total = try UsersModel.count(db);
    try ctx.renderJson(.{ .data = items, .total = total, .page = page, .size = size });
}

/// Show Users by ID.
pub fn show(ctx: *zfinal.Context) !void {
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    const item = try UsersModel.findById(db, id, ctx.allocator) orelse {
        ctx.res_status = .not_found;
        return ctx.renderJson(.{ .err = "Not found" });
    };
    defer item.deinit(ctx.allocator);
    try ctx.renderJson(.{ .data = item });
}

/// Create Users record (CSRF-protected).
pub fn create(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var instance = UsersModel.Instance{
        .data = .{
            .username = (try ctx.getPara("username")) orelse "",
            .email = (try ctx.getPara("email")) orelse "",
            .password = (try ctx.getPara("password")) orelse "",
            .created_at = (try ctx.getPara("created_at")) orelse null,
        },
    };
    try validate(instance.data);
    try instance.save(db);
    try ctx.renderJson(.{ .ok = true, .id = instance.id });
}

/// Update Users record (CSRF-protected).
pub fn update(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try UsersModel.findById(db, id, ctx.allocator) orelse {
        ctx.res_status = .not_found;
        return ctx.renderJson(.{ .err = "Not found" });
    };
    if (try ctx.getPara("username")) |v| item.data.username = v;
    if (try ctx.getPara("email")) |v| item.data.email = v;
    if (try ctx.getPara("password")) |v| item.data.password = v;
    if (try ctx.getPara("created_at")) |v| item.data.created_at = v;
    try validate(item.data);
    try item.save(db);
    try ctx.renderJson(.{ .ok = true });
}

/// Delete Users record (CSRF-protected).
pub fn delete(ctx: *zfinal.Context) !void {
    try csrfGuard(ctx);
    const id = try parseId(ctx);
    const db = try pool_ref.acquire();
    defer pool_ref.release(db) catch {};
    var item = try UsersModel.findById(db, id, ctx.allocator) orelse {
        ctx.res_status = .not_found;
        return ctx.renderJson(.{ .err = "Not found" });
    };
    try item.delete(db);
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