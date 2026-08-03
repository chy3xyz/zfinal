//! Org HTTP handlers.
const std = @import("std");
const zfinal = @import("zfinal");
const service = @import("service.zig");
const auth_service = @import("../auth/service.zig");
const state_mod = @import("../../state.zig");
const json_api = @import("../../json_api.zig");

fn requireUserId(ctx: *zfinal.Context) !i64 {
    const sub = ctx.getAttr("jwt_sub") orelse return error.Unauthorized;
    return std.fmt.parseInt(i64, sub, 10);
}

pub fn list(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    const uid = try requireUserId(ctx);
    const rows = try service.listOrgs(st.db, ctx.allocator, uid);
    defer service.freeOrgs(ctx.allocator, rows);
    try json_api.ok(ctx, rows);
}

const CreateBody = struct { name: []const u8 = "" };

pub fn create(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    const uid = try requireUserId(ctx);
    var body: CreateBody = .{};
    try ctx.bindJson(&body);
    const org_id = service.createOrg(st.db, ctx.allocator, uid, body.name) catch |e| {
        return switch (e) {
            error.ValidationError => json_api.err(ctx, .bad_request, "validation"),
            else => e,
        };
    };
    defer ctx.allocator.free(org_id);
    const token = try auth_service.issueToken(ctx.allocator, st.jwt_secret, uid, org_id, "admin", st.jwt_ttl_sec);
    defer ctx.allocator.free(token);
    try json_api.ok(ctx, .{ .org_id = org_id, .token = token, .role = "admin" });
}

const SwitchBody = struct { org_id: []const u8 = "" };

pub fn switchOrg(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    const uid = try requireUserId(ctx);
    var body: SwitchBody = .{};
    try ctx.bindJson(&body);
    const token = service.switchOrg(st.db, ctx.allocator, uid, body.org_id, st.jwt_secret, st.jwt_ttl_sec) catch {
        return json_api.err(ctx, .forbidden, "not_a_member");
    };
    defer ctx.allocator.free(token);
    try json_api.ok(ctx, .{ .token = token, .org_id = body.org_id });
}

const InviteBody = struct {
    email: []const u8 = "",
    role: ?[]const u8 = null,
};

pub fn invite(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    const uid = try requireUserId(ctx);
    const org_id = ctx.getPathParam("id") orelse return json_api.err(ctx, .bad_request, "org_id");
    const role_attr = ctx.getAttr("jwt_role") orelse "";
    if (!std.mem.eql(u8, role_attr, "admin")) return json_api.err(ctx, .forbidden, "admin_required");
    // Ensure caller is admin of this org
    const mem = try service.membershipRole(st.db, ctx.allocator, uid, org_id) orelse return json_api.err(ctx, .forbidden, "not_a_member");
    defer ctx.allocator.free(mem);
    if (!std.mem.eql(u8, mem, "admin")) return json_api.err(ctx, .forbidden, "admin_required");

    var body: InviteBody = .{};
    try ctx.bindJson(&body);
    zfinal.auditLog(.invite_sent, "/api/orgs/:id/invites", body.email);
    const role = body.role orelse "member";
    const inv = service.createInvite(st.db, ctx.allocator, org_id, body.email, role, uid, &st.email) catch |e| {
        return switch (e) {
            error.ValidationError => json_api.err(ctx, .bad_request, "validation"),
            else => e,
        };
    };
    defer ctx.allocator.free(inv.raw_token);
    try json_api.ok(ctx, .{ .invite_id = inv.invite_id, .token = inv.raw_token });
}

const AcceptBody = struct { token: []const u8 = "" };

pub fn acceptInvite(ctx: *zfinal.Context) !void {
    const st = try state_mod.fromContext(ctx);
    const uid = try requireUserId(ctx);
    const user = try auth_service.findUser(st.db, ctx.allocator, uid) orelse return json_api.err(ctx, .not_found, "user");
    defer {
        ctx.allocator.free(user.email);
        ctx.allocator.free(user.name);
        ctx.allocator.free(user.locale);
    }
    var body: AcceptBody = .{};
    try ctx.bindJson(&body);
    const org_id = service.acceptInvite(st.db, ctx.allocator, uid, user.email, body.token) catch |e| {
        return switch (e) {
            error.NotFound => json_api.err(ctx, .not_found, "invite"),
            error.Gone => json_api.err(ctx, .gone, "invite_used_or_expired"),
            error.Forbidden => json_api.err(ctx, .forbidden, "email_mismatch"),
            else => e,
        };
    };
    defer ctx.allocator.free(org_id);
    const role_owned = try service.membershipRole(st.db, ctx.allocator, uid, org_id) orelse try ctx.allocator.dupe(u8, "member");
    defer ctx.allocator.free(role_owned);

    const token = try auth_service.issueToken(ctx.allocator, st.jwt_secret, uid, org_id, role_owned, st.jwt_ttl_sec);
    defer ctx.allocator.free(token);
    try json_api.ok(ctx, .{ .org_id = org_id, .token = token, .role = role_owned });
}
