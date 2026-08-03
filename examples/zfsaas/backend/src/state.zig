//! Shared app state for SaaS Kit (DB + JWT + Stripe env).
const std = @import("std");
const zfinal = @import("zfinal");

pub const AppState = struct {
    db: *zfinal.DB,
    allocator: std.mem.Allocator,
    jwt_secret: []const u8,
    jwt_ttl_sec: i64 = 60 * 60 * 24 * 7, // 7 days
    stripe_secret: ?[]const u8 = null,
    stripe_webhook_secret: ?[]const u8 = null,
    stripe_price_id: ?[]const u8 = null,
    /// Public site URL for Stripe success/cancel redirects.
    public_base_url: []const u8 = "http://127.0.0.1:8080",
    /// Monthly per-org todo quota (metered billing). 0 = unlimited.
    todo_monthly_quota: i64 = 100,
    /// Comma-separated emails allowed to access /api/admin/* (super admin).
    super_admin_csv: []const u8 = "",
    email: EmailSender = .{},
};

/// Log/mock email port (Resend live left for later).
pub const EmailSender = struct {
    pub fn send(_: *const EmailSender, to: []const u8, subject: []const u8, body: []const u8) void {
        std.debug.print("[email-mock] to={s} subject={s} body={s}\n", .{ to, subject, body });
    }
};

pub fn fromContext(ctx: *zfinal.Context) !*AppState {
    return try ctx.state(AppState);
}
