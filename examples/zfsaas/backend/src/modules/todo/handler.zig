//! Todo HTTP — Bearer JWT + org_id scope + active subscription on writes.
const std = @import("std");
const zfinal = @import("zfinal");
const service = @import("service.zig");
const billing = @import("../billing/service.zig");
const state_mod = @import("../../state.zig");
const json_api = @import("../../json_api.zig");

fn requireOrg(ctx: *zfinal.Context) ![]const u8 {
    return ctx.getAttr("jwt_org") orelse return error.Unauthorized;
}

fn requireUser(ctx: *zfinal.Context) ![]const u8 {
    return ctx.getAttr("jwt_sub") orelse return error.Unauthorized;
}

const TodoView = struct {
    id: ?i64,
    owner_id: []const u8,
    org_id: []const u8,
    title: []const u8,
    message: []const u8,
};

fn todoJson(it: service.Instance) TodoView {
    return .{
        .id = it.id,
        .owner_id = it.data.owner_id,
        .org_id = it.data.org_id,
        .title = it.data.title,
        .message = it.data.message,
    };
}

/// Declarative list filters (ADR-017) — bound from query params.
/// `page` opt-in: when present, returns `{data, meta:{total,page,size}}`
/// (backward compatible — `data` stays an array).
const ListFilters = struct {
    q: ?[]const u8 = null,
    page: ?i64 = null,
    size: ?i64 = null,
};

pub fn list(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    const org_id = try requireOrg(ctx);
    var f: ListFilters = .{};
    try ctx.bindQuery(&f);
    if (f.page) |p| {
        const size: usize = @intCast(@min(f.size orelse 20, 100));
        var page = try service.paginateByOrg(st.db, ctx.allocator, org_id, f.q, @intCast(p), size);
        defer {
            for (page.list) |*it| it.deinit(ctx.allocator);
            page.deinit();
        }
        var out: std.ArrayList(TodoView) = .empty;
        defer out.deinit(ctx.allocator);
        for (page.list) |it| try out.append(ctx.allocator, todoJson(it));
        try json_api.okMeta(ctx, out.items, .{ .total = page.total_row, .page = page.page_number, .size = page.page_size });
        return;
    }
    const items = try service.listByOrg(st.db, ctx.allocator, org_id, f.q);
    defer {
        for (items) |*it| it.deinit(ctx.allocator);
        ctx.allocator.free(items);
    }
    var out: std.ArrayList(TodoView) = .empty;
    defer out.deinit(ctx.allocator);
    for (items) |it| try out.append(ctx.allocator, todoJson(it));
    try json_api.ok(ctx, out.items);
}

pub fn show(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    const org_id = try requireOrg(ctx);
    const id = try zfinal.extract.requireParamInt(ctx, i64, "id");
    const item = try service.findByIdInOrg(st.db, ctx.allocator, id, org_id) orelse {
        return json_api.err(ctx, .not_found, "todo");
    };
    defer item.deinit(ctx.allocator);
    try json_api.ok(ctx, todoJson(item));
}

const CreateBody = struct {
    title: []const u8 = "",
    message: ?[]const u8 = null,
};

pub fn create(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    const org_id = try requireOrg(ctx);
    const owner = try requireUser(ctx);
    billing.requireActiveSubscription(st.db, org_id) catch {
        return json_api.err(ctx, .payment_required, "subscription_required");
    };
    var body: CreateBody = .{};
    try ctx.bindJson(&body);
    const msg = body.message orelse "";
    const instance = service.createInOrg(st.db, body.title, msg, org_id, owner) catch |e| {
        return switch (e) {
            error.ValidationError => json_api.err(ctx, .bad_request, "validation"),
            else => e,
        };
    };
    try json_api.ok(ctx, .{ .id = instance.id, .org_id = org_id, .title = body.title });
}

const UpdateBody = struct {
    title: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub fn update(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    const org_id = try requireOrg(ctx);
    billing.requireActiveSubscription(st.db, org_id) catch {
        return json_api.err(ctx, .payment_required, "subscription_required");
    };
    const id = try zfinal.extract.requireParamInt(ctx, i64, "id");
    var body: UpdateBody = .{};
    try ctx.bindJson(&body);
    var item = service.updateInOrg(st.db, ctx.allocator, id, org_id, body.title, body.message) catch |e| {
        return switch (e) {
            error.NotFound => json_api.err(ctx, .not_found, "todo"),
            else => e,
        };
    };
    defer item.deinit(ctx.allocator);
    try json_api.ok(ctx, todoJson(item));
}

pub fn delete(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    const org_id = try requireOrg(ctx);
    billing.requireActiveSubscription(st.db, org_id) catch {
        return json_api.err(ctx, .payment_required, "subscription_required");
    };
    const id = try zfinal.extract.requireParamInt(ctx, i64, "id");
    service.deleteInOrg(st.db, ctx.allocator, id, org_id) catch |e| {
        return switch (e) {
            error.NotFound => json_api.err(ctx, .not_found, "todo"),
            else => e,
        };
    };
    try json_api.okEmpty(ctx);
}

// ── ai-edit-zone: handler hooks ─────────────────────────────────
// Subscription gate on write paths; org_id from JWT aud.
// ────────────────────────────────────────────────────────────────
