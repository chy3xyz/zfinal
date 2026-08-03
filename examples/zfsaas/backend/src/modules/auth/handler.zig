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
        .user = .{ .id = result.user_id, .email = result.email, .name = result.name },
        .org_id = result.org_id,
        .role = result.role,
    });
}

pub fn signIn(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    var body: SignBody = .{};
    try ctx.bindJson(&body);
    const result = service.signIn(st.db, ctx.allocator, body.email, body.password, st.jwt_secret, st.jwt_ttl_sec) catch {
        return json_api.err(ctx, .unauthorized, "invalid_credentials");
    };
    defer service.freeAuthResult(ctx.allocator, result);
    try json_api.ok(ctx, .{
        .token = result.token,
        .user = .{ .id = result.user_id, .email = result.email, .name = result.name },
        .org_id = result.org_id,
        .role = result.role,
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
    try json_api.ok(ctx, .{
        .id = user.id,
        .email = user.email,
        .name = user.name,
        .locale = user.locale,
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
