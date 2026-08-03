//! Auth HTTP handlers.
const std = @import("std");
const zfinal = @import("zfinal");
const service = @import("service.zig");
const state_mod = @import("../../state.zig");
const json_api = @import("../../json_api.zig");

const SignBody = struct {
    email: []const u8 = "",
    password: []const u8 = "",
    name: ?[]const u8 = null,
};

pub fn signUp(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    var body: SignBody = .{};
    try ctx.bindJson(&body);
    const name = body.name orelse "User";
    const result = service.signUp(st.db, ctx.allocator, body.email, name, body.password, st.jwt_secret, st.jwt_ttl_sec) catch |e| {
        return switch (e) {
            error.EmailTaken => json_api.err(ctx, .conflict, "email_taken"),
            error.WeakPassword => json_api.err(ctx, .bad_request, "weak_password"),
            error.ValidationError => json_api.err(ctx, .bad_request, "validation"),
            else => e,
        };
    };
    defer service.freeAuthResult(ctx.allocator, result);
    try json_api.ok(ctx, .{
        .token = result.token,
        .refresh_token = result.refresh_token,
        .dev_verify_token = result.verify_token,
        .user = .{ .id = result.user_id, .email = result.email, .name = result.name },
        .org_id = result.org_id,
        .role = result.role,
        .email_verified = result.email_verified,
    });
}

pub fn signIn(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    var body: SignBody = .{};
    try ctx.bindJson(&body);
    const result = service.signIn(st.db, ctx.allocator, body.email, body.password, st.jwt_secret, st.jwt_ttl_sec) catch {
        zfinal.auditLog(.auth_fail, "/api/auth/sign-in", body.email);
        return json_api.err(ctx, .unauthorized, "invalid_credentials");
    };
    defer service.freeAuthResult(ctx.allocator, result);
    try json_api.ok(ctx, .{
        .token = result.token,
        .refresh_token = result.refresh_token,
        .dev_verify_token = result.verify_token,
        .user = .{ .id = result.user_id, .email = result.email, .name = result.name },
        .org_id = result.org_id,
        .role = result.role,
        .email_verified = result.email_verified,
    });
}

pub fn me(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    const sub = ctx.getAttr("jwt_sub") orelse return json_api.err(ctx, .unauthorized, "jwt");
    const user_id = try std.fmt.parseInt(i64, sub, 10);
    const user = try service.findUser(st.db, ctx.allocator, user_id) orelse return json_api.err(ctx, .not_found, "user");
    defer {
        ctx.allocator.free(user.email);
        ctx.allocator.free(user.name);
        ctx.allocator.free(user.locale);
    }
    var vrs = try st.db.queryParams("SELECT email_verified_at FROM users WHERE id = ?", &.{.{ .int = user_id }});
    defer vrs.deinit();
    const verified = if (vrs.next()) vrs.getText(0) != null else false;
    try json_api.ok(ctx, .{
        .id = user.id,
        .email = user.email,
        .name = user.name,
        .locale = user.locale,
        .email_verified = verified,
        .org_id = ctx.getAttr("jwt_org"),
        .role = ctx.getAttr("jwt_role"),
    });
}

const ResetRequestBody = struct { email: []const u8 = "" };
const ResetConfirmBody = struct { token: []const u8 = "", password: []const u8 = "" };

pub fn requestReset(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    var body: ResetRequestBody = .{};
    try ctx.bindJson(&body);
    // Always ok (no email enumeration); mock returns token in data when found (dev).
    zfinal.auditLog(.email_sent, "/api/auth/password-reset/request", body.email);
    const raw = try service.requestPasswordReset(st.db, ctx.allocator, body.email, &st.email);
    if (raw) |t| {
        defer ctx.allocator.free(t);
        try json_api.ok(ctx, .{ .sent = true, .dev_token = t });
    } else {
        try json_api.ok(ctx, .{ .sent = true, .dev_token = null });
    }
}

pub fn confirmReset(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    var body: ResetConfirmBody = .{};
    try ctx.bindJson(&body);
    service.resetPassword(st.db, ctx.allocator, body.token, body.password) catch |e| {
        return switch (e) {
            error.WeakPassword => json_api.err(ctx, .bad_request, "weak_password"),
            error.NotFound => json_api.err(ctx, .not_found, "token"),
            error.Gone => json_api.err(ctx, .gone, "token_used_or_expired"),
            else => e,
        };
    };
    try json_api.okEmpty(ctx);
}

const RefreshBody = struct { refresh_token: []const u8 = "" };
const VerifyBody = struct { token: []const u8 = "" };

/// Rotate refresh token → new access + refresh (P1).
pub fn refresh(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    var body: RefreshBody = .{};
    try ctx.bindJson(&body);
    const result = service.refreshSession(st.db, ctx.allocator, body.refresh_token, st.jwt_secret, st.jwt_ttl_sec) catch {
        return json_api.err(ctx, .unauthorized, "invalid_refresh");
    };
    defer service.freeAuthResult(ctx.allocator, result);
    try json_api.ok(ctx, .{
        .token = result.token,
        .refresh_token = result.refresh_token,
        .user = .{ .id = result.user_id, .email = result.email, .name = result.name },
        .org_id = result.org_id,
        .role = result.role,
        .email_verified = result.email_verified,
    });
}

/// Revoke a refresh token (logout).
pub fn revoke(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    var body: RefreshBody = .{};
    try ctx.bindJson(&body);
    try service.revokeRefresh(st.db, ctx.allocator, body.refresh_token);
    try json_api.okEmpty(ctx);
}

/// Verify email via the token returned at sign-up (P1).
pub fn verifyEmail(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    var body: VerifyBody = .{};
    try ctx.bindJson(&body);
    service.verifyEmail(st.db, ctx.allocator, body.token) catch |e| {
        return switch (e) {
            error.NotFound => json_api.err(ctx, .not_found, "token"),
            error.Gone => json_api.err(ctx, .gone, "token_used_or_expired"),
            else => e,
        };
    };
    try json_api.okEmpty(ctx);
}
