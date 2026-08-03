//! Billing: subscription status, Stripe checkout (mock/live), webhook + gate.
const std = @import("std");
const zfinal = @import("zfinal");
const util = @import("../../util.zig");

pub const SubRow = struct {
    org_id: []const u8,
    status: []const u8,
    stripe_subscription_id: ?[]const u8,
    stripe_price_id: ?[]const u8,
    current_period_end: ?[]const u8,
};

pub fn getSubscription(db: *zfinal.DB, allocator: std.mem.Allocator, org_id: []const u8) !?SubRow {
    var rs = try db.queryParams(
        "SELECT org_id, status, stripe_subscription_id, stripe_price_id, current_period_end FROM subscriptions WHERE org_id = ?",
        &.{.{ .text = org_id }},
    );
    defer rs.deinit();
    if (!rs.next()) return null;
    return .{
        .org_id = try allocator.dupe(u8, rs.getText(0).?),
        .status = try allocator.dupe(u8, rs.getText(1).?),
        .stripe_subscription_id = if (rs.getText(2)) |t| try allocator.dupe(u8, t) else null,
        .stripe_price_id = if (rs.getText(3)) |t| try allocator.dupe(u8, t) else null,
        .current_period_end = if (rs.getText(4)) |t| try allocator.dupe(u8, t) else null,
    };
}

pub fn freeSub(allocator: std.mem.Allocator, s: SubRow) void {
    allocator.free(s.org_id);
    allocator.free(s.status);
    if (s.stripe_subscription_id) |t| allocator.free(t);
    if (s.stripe_price_id) |t| allocator.free(t);
    if (s.current_period_end) |t| allocator.free(t);
}

pub fn isActiveStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "active") or std.mem.eql(u8, status, "trialing");
}

/// Gate for premium routes — true when org has active/trialing subscription.
pub fn requireActiveSubscription(db: *zfinal.DB, org_id: []const u8) !void {
    var rs = try db.queryParams("SELECT status FROM subscriptions WHERE org_id = ?", &.{.{ .text = org_id }});
    defer rs.deinit();
    if (!rs.next()) return error.PaymentRequired;
    if (!isActiveStatus(rs.getText(0).?)) return error.PaymentRequired;
}

pub const CheckoutResult = struct {
    url: []const u8,
    mock: bool,
};

/// Create Stripe Checkout Session when STRIPE_SECRET is set; else mock URL.
pub fn createCheckout(
    allocator: std.mem.Allocator,
    org_id: []const u8,
    stripe_secret: ?[]const u8,
    price_id: ?[]const u8,
    public_base: []const u8,
    db: *zfinal.DB,
) !CheckoutResult {
    if (stripe_secret == null or price_id == null) {
        // Mock: activate on "checkout" for local/CI demos.
        try db.execParams(
            "UPDATE subscriptions SET status = ?, updated_at = datetime('now') WHERE org_id = ?",
            &.{ .{ .text = "active" }, .{ .text = org_id } },
        );
        const url = try std.fmt.allocPrint(allocator, "{s}/billing/mock-success?org={s}", .{ public_base, org_id });
        return .{ .url = url, .mock = true };
    }

    var client = try zfinal.HttpClient.init(allocator, "https://api.stripe.com");
    defer client.deinit();

    const success = try std.fmt.allocPrint(allocator, "{s}/billing/success", .{public_base});
    defer allocator.free(success);
    const cancel = try std.fmt.allocPrint(allocator, "{s}/billing/cancel", .{public_base});
    defer allocator.free(cancel);

    const form = try std.fmt.allocPrint(
        allocator,
        "mode=subscription&success_url={s}&cancel_url={s}&line_items[0][price]={s}&line_items[0][quantity]=1&client_reference_id={s}&metadata[org_id]={s}",
        .{ success, cancel, price_id.?, org_id, org_id },
    );
    defer allocator.free(form);

    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{stripe_secret.?});
    defer allocator.free(auth);

    var resp = try client.requestWith(.POST, "/v1/checkout/sessions", form, &.{
        .{ .name = "authorization", .value = auth },
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
    });
    defer resp.deinit();
    if (resp.status < 200 or resp.status >= 300) return error.StripeError;

    // Minimal parse: "url":"..."
    const url = try extractJsonString(allocator, resp.body, "url") orelse return error.StripeError;
    return .{ .url = url, .mock = false };
}

fn extractJsonString(allocator: std.mem.Allocator, json: []const u8, key: []const u8) !?[]u8 {
    const needle = try std.fmt.allocPrint(allocator, "\"{s}\":\"", .{key});
    defer allocator.free(needle);
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const from = start + needle.len;
    const end = std.mem.indexOfScalar(u8, json[from..], '"') orelse return null;
    return try allocator.dupe(u8, json[from .. from + end]);
}

pub const WebhookOutcome = enum { processed, duplicate, ignored };

/// Process Stripe webhook (or mock body). Idempotent via stripe_webhook_events.
/// Mock body shape: `{"id":"evt_x","type":"customer.subscription.updated","data":{"object":{"metadata":{"org_id":"..."},"status":"active"}}}`
pub fn handleWebhook(
    db: *zfinal.DB,
    event_id: []const u8,
    event_type: []const u8,
    org_id: ?[]const u8,
    status: ?[]const u8,
) !WebhookOutcome {
    db.execParams(
        "INSERT INTO stripe_webhook_events (id, type) VALUES (?, ?)",
        &.{ .{ .text = event_id }, .{ .text = event_type } },
    ) catch return .duplicate;

    if (org_id) |oid| {
        if (status) |st| {
            try db.execParams(
                "UPDATE subscriptions SET status = ?, updated_at = datetime('now') WHERE org_id = ?",
                &.{ .{ .text = st }, .{ .text = oid } },
            );
            return .processed;
        }
    }
    return .ignored;
}

/// Verify Stripe-Signature header when secret present. Mock mode skips.
pub fn verifyStripeSignature(
    allocator: std.mem.Allocator,
    webhook_secret: ?[]const u8,
    payload: []const u8,
    sig_header: ?[]const u8,
) !bool {
    const secret = webhook_secret orelse return true;
    const hdr = sig_header orelse return false;
    // Stripe: t=timestamp,v1=hex
    var t_val: ?[]const u8 = null;
    var v1_val: ?[]const u8 = null;
    var iter = std.mem.splitScalar(u8, hdr, ',');
    while (iter.next()) |part| {
        if (std.mem.startsWith(u8, part, "t=")) t_val = part[2..];
        if (std.mem.startsWith(u8, part, "v1=")) v1_val = part[3..];
    }
    const t = t_val orelse return false;
    const v1 = v1_val orelse return false;
    const signed = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ t, payload });
    defer allocator.free(signed);
    const expect = try util.hmacSha256Hex(allocator, secret, signed);
    defer allocator.free(expect);
    return std.ascii.eqlIgnoreCase(expect, v1);
}
