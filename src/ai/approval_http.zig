//! Light HTTP surface for human approval queues.
//!
//! `GET /approvals/pending` — list pending runs  
//! `POST /approvals/:id/approve` / `POST /approvals/:id/reject` — resolve
//!
//! Production defaults: `require_tenant=true`. Bind with `bindWith` and mount JWT/CSRF
//! interceptors on the same router (or set `authorize`).

const std = @import("std");
const Router = @import("../core/router.zig").Router;
const Context = @import("../core/context.zig").Context;
const ApprovalFlow = @import("approval.zig").ApprovalFlow;
const PendingItem = @import("approval.zig").PendingItem;

pub const HttpOpts = struct {
    /// When true (default), `X-Tenant-ID` is required on every call.
    require_tenant: bool = true,
    /// Optional gate — return false → 401. Use for JWT / API key checks.
    authorize: ?*const fn (*Context) bool = null,
};

var bound_flow: ?*ApprovalFlow = null;
var bound_opts: HttpOpts = .{};

pub fn bind(flow: *ApprovalFlow) void {
    bindWith(flow, .{});
}

pub fn bindWith(flow: *ApprovalFlow, opts: HttpOpts) void {
    bound_flow = flow;
    bound_opts = opts;
}

pub fn unbind() void {
    bound_flow = null;
    bound_opts = .{};
}

/// Register fixed paths under `/approvals/...`. Call `bind` / `bindWith` before serving.
pub fn register(router: *Router) !void {
    try router.addWithMethod("/approvals/pending", .GET, listPending);
    try router.addWithMethod("/approvals/:id/approve", .POST, approve);
    try router.addWithMethod("/approvals/:id/reject", .POST, reject);
}

fn gate(ctx: *Context) !bool {
    if (bound_opts.authorize) |auth| {
        if (!auth(ctx)) {
            ctx.res_status = .unauthorized;
            try ctx.renderJson(.{ .@"error" = "unauthorized" });
            return false;
        }
    }
    return true;
}

fn requireTenant(ctx: *Context) !?i64 {
    const h = ctx.getHeader("X-Tenant-ID");
    if (h == null) {
        if (bound_opts.require_tenant) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "missing_tenant" });
            return error.MissingTenant;
        }
        return null;
    }
    return std.fmt.parseInt(i64, h.?, 10) catch {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "invalid_tenant" });
        return error.InvalidTenant;
    };
}

fn listPending(ctx: *Context) !void {
    if (!try gate(ctx)) return;
    const flow = bound_flow orelse {
        ctx.res_status = .service_unavailable;
        try ctx.renderJson(.{ .@"error" = "approval_flow_not_bound" });
        return;
    };
    const tenant_id = requireTenant(ctx) catch return;

    var items = std.ArrayList(PendingItem).empty;
    defer {
        for (items.items) |p| {
            ctx.allocator.free(p.run_id);
            ctx.allocator.free(p.subject);
            ctx.allocator.free(p.request);
            ctx.allocator.free(p.step_name);
        }
        items.deinit(ctx.allocator);
    }
    try flow.listPending(ctx.allocator, &items, tenant_id);

    const Row = struct {
        run_id: []const u8,
        subject: []const u8,
        amount: i64,
        step: []const u8,
        created_at_ms: i64,
        tenant_id: ?i64 = null,
    };
    var rows = try ctx.allocator.alloc(Row, items.items.len);
    defer ctx.allocator.free(rows);
    for (items.items, 0..) |p, i| {
        rows[i] = .{
            .run_id = p.run_id,
            .subject = p.subject,
            .amount = p.amount,
            .step = p.step_name,
            .created_at_ms = p.created_at_ms,
            .tenant_id = p.tenant_id,
        };
    }
    try ctx.renderJson(.{ .pending = rows });
}

fn approve(ctx: *Context) !void {
    try resolveHandler(ctx, true);
}

fn reject(ctx: *Context) !void {
    try resolveHandler(ctx, false);
}

fn resolveHandler(ctx: *Context, approve_flag: bool) !void {
    if (!try gate(ctx)) return;
    const flow = bound_flow orelse {
        ctx.res_status = .service_unavailable;
        try ctx.renderJson(.{ .@"error" = "approval_flow_not_bound" });
        return;
    };
    const id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .ok = false, .@"error" = "missing_id" });
        return;
    };
    const tenant_id = requireTenant(ctx) catch return;
    const ok = flow.resolveForTenant(id, approve_flag, tenant_id);
    if (!ok) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .ok = false, .@"error" = "not_found" });
        return;
    }
    try ctx.renderJson(.{ .ok = true, .approved = approve_flag, .run_id = id });
}

test "approval http list and resolve via capture" {
    const allocator = std.testing.allocator;
    const oneshot = @import("../core/oneshot.zig");
    const defaultPolicy = @import("approval.zig").defaultPolicy;
    const ApprovalStep = @import("approval.zig").ApprovalStep;
    const SkillContext = @import("skill.zig").SkillContext;

    var flow = ApprovalFlow.init(allocator, std.testing.io, defaultPolicy);
    defer flow.deinit();
    bindWith(&flow, .{ .require_tenant = false });
    defer unbind();

    const steps = [_]ApprovalStep{.{ .name = "manager" }};
    var sctx = SkillContext{ .allocator = allocator };
    var submitted = try flow.submit(allocator, &sctx, "order-http", 42, "refund", &steps);
    defer submitted.deinit(allocator);
    try std.testing.expectEqualStrings("pending_human", @tagName(submitted.status));

    var router = Router.init(allocator);
    defer router.deinit();
    try register(&router);
    try router.seal();

    var listed = try oneshot.capture(allocator, &router, .GET, "/approvals/pending", .{});
    defer listed.deinit();
    try std.testing.expectEqual(@as(u16, 200), listed.status);
    try std.testing.expect(std.mem.indexOf(u8, listed.body, submitted.run_id) != null);

    const approve_path = try std.fmt.allocPrint(allocator, "/approvals/{s}/approve", .{submitted.run_id});
    defer allocator.free(approve_path);
    var approved = try oneshot.capture(allocator, &router, .POST, approve_path, .{});
    defer approved.deinit();
    try std.testing.expectEqual(@as(u16, 200), approved.status);
    try std.testing.expect(std.mem.indexOf(u8, approved.body, "\"ok\":true") != null);

    var empty = try oneshot.capture(allocator, &router, .GET, "/approvals/pending", .{});
    defer empty.deinit();
    try std.testing.expect(std.mem.indexOf(u8, empty.body, "\"pending\":[]") != null or std.mem.indexOf(u8, empty.body, "\"pending\": []") != null);
}

test "approval http require_tenant rejects missing header" {
    const allocator = std.testing.allocator;
    const oneshot = @import("../core/oneshot.zig");
    const defaultPolicy = @import("approval.zig").defaultPolicy;

    var flow = ApprovalFlow.init(allocator, std.testing.io, defaultPolicy);
    defer flow.deinit();
    bind(&flow); // require_tenant=true
    defer unbind();

    var router = Router.init(allocator);
    defer router.deinit();
    try register(&router);
    try router.seal();

    var res = try oneshot.capture(allocator, &router, .GET, "/approvals/pending", .{});
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 400), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "missing_tenant") != null);
}

test "approval http reject records lookup rejected" {
    const allocator = std.testing.allocator;
    const oneshot = @import("../core/oneshot.zig");
    const defaultPolicy = @import("approval.zig").defaultPolicy;
    const ApprovalStep = @import("approval.zig").ApprovalStep;
    const SkillContext = @import("skill.zig").SkillContext;
    const ResolveStatus = @import("approval.zig").ResolveStatus;

    var flow = ApprovalFlow.init(allocator, std.testing.io, defaultPolicy);
    defer flow.deinit();
    bindWith(&flow, .{ .require_tenant = false });
    defer unbind();

    const steps = [_]ApprovalStep{.{ .name = "manager" }};
    var sctx = SkillContext{ .allocator = allocator };
    var submitted = try flow.submit(allocator, &sctx, "order-rej", 1, "x", &steps);
    defer submitted.deinit(allocator);

    var router = Router.init(allocator);
    defer router.deinit();
    try register(&router);
    try router.seal();

    const path = try std.fmt.allocPrint(allocator, "/approvals/{s}/reject", .{submitted.run_id});
    defer allocator.free(path);
    var res = try oneshot.capture(allocator, &router, .POST, path, .{});
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqual(ResolveStatus.rejected, flow.lookup(submitted.run_id));
}
