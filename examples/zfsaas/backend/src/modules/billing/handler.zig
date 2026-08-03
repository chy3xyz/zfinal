//! Billing HTTP handlers.
const std = @import("std");
const zfinal = @import("zfinal");
const service = @import("service.zig");
const state_mod = @import("../../state.zig");
const json_api = @import("../../json_api.zig");

fn requireOrg(ctx: *zfinal.Context) ![]const u8 {
    return ctx.getAttr("jwt_org") orelse return error.Unauthorized;
}

pub fn subscription(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    const org_id = try requireOrg(ctx);
    const sub = try service.getSubscription(st.db, ctx.allocator, org_id) orelse {
        return json_api.ok(ctx, .{ .status = "inactive", .org_id = org_id });
    };
    defer service.freeSub(ctx.allocator, sub);
    try json_api.ok(ctx, sub);
}

pub fn checkout(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    const org_id = try requireOrg(ctx);
    zfinal.auditLog(.subscription_changed, "/api/billing/checkout", org_id);
    const result = try service.createCheckout(
        ctx.allocator,
        org_id,
        st.stripe_secret,
        st.stripe_price_id,
        st.public_base_url,
        st.db,
    );
    defer ctx.allocator.free(result.url);
    try json_api.ok(ctx, .{ .url = result.url, .mock = result.mock });
}

const MockWebhook = struct {
    id: []const u8,
    type: []const u8,
    org_id: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

pub fn webhook(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    const body = try ctx.getBodyText();
    defer ctx.allocator.free(body);
    const sig = ctx.getHeader("Stripe-Signature");
    const ok_sig = try service.verifyStripeSignature(ctx.allocator, st.stripe_webhook_secret, body, sig);
    if (!ok_sig) return json_api.err(ctx, .unauthorized, "invalid_signature");

    const parsed = std.json.parseFromSlice(MockWebhook, ctx.allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return json_api.err(ctx, .bad_request, "invalid_json");
    };
    defer parsed.deinit();
    const ev = parsed.value;
    const outcome = try service.handleWebhook(st.db, ev.id, ev.type, ev.org_id, ev.status);
    try json_api.ok(ctx, .{ .outcome = @tagName(outcome) });
}
