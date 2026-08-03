//! JWT interceptor that also sets `jwt_org` from claim `aud`.
//! Optional `X-Org-Id` must match `aud` when both present.
const std = @import("std");
const zfinal = @import("zfinal");
const org_service = @import("modules/org/service.zig");
const state_mod = @import("state.zig");
const json_api = @import("json_api.zig");

pub var jwt_cfg: zfinal.JwtAuthConfig = undefined;

/// Verify Bearer JWT; store sub/role/org(aud). Does not require membership (use orgGuard).
pub fn jwtBefore(ctx: *zfinal.Context, ud: ?*anyopaque) !bool {
    const c: *const zfinal.JwtAuthConfig = @ptrCast(@alignCast(ud.?));
    const hdr = ctx.getHeader("Authorization") orelse {
        try json_api.err(ctx, .unauthorized, "missing_bearer");
        return false;
    };
    const prefix = "Bearer ";
    if (hdr.len <= prefix.len or !std.ascii.eqlIgnoreCase(hdr[0..prefix.len], prefix)) {
        try json_api.err(ctx, .unauthorized, "missing_bearer");
        return false;
    }
    const token = hdr[prefix.len..];
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const now: i64 = @intCast(ts.sec);

    const claims = zfinal.jwtVerifyWithOptions(ctx.allocator, c.secret, token, now, c.opts) catch {
        try json_api.err(ctx, .unauthorized, "invalid_jwt");
        return false;
    };
    defer zfinal.jwtFreeClaims(ctx.allocator, claims);
    try ctx.setAttr("jwt_sub", claims.sub);
    if (claims.role) |role| try ctx.setAttr("jwt_role", role);
    if (claims.aud) |aud| try ctx.setAttr("jwt_org", aud);

    if (ctx.getHeader("X-Org-Id")) |xorg| {
        if (claims.aud) |aud| {
            if (!std.mem.eql(u8, xorg, aud)) {
                try json_api.err(ctx, .forbidden, "org_mismatch");
                return false;
            }
        } else {
            try ctx.setAttr("jwt_org", xorg);
        }
    }

    try ctx.setExt(zfinal.extension.JwtIdentity, .{
        .sub = ctx.getAttr("jwt_sub").?,
        .role = ctx.getAttr("jwt_role") orelse "",
    });
    return true;
}

pub fn createJwtInterceptor(cfg: *const zfinal.JwtAuthConfig) zfinal.Interceptor {
    return .{
        .name = "saas_jwt",
        .userdata = @constCast(cfg),
        .before_ud = jwtBefore,
    };
}

/// Ensure jwt_org is set and user is a member of that org.
pub fn orgMemberBefore(ctx: *zfinal.Context, _: ?*anyopaque) !bool {
    const st = try state_mod.fromContext(ctx);
    const sub = ctx.getAttr("jwt_sub") orelse {
        try json_api.err(ctx, .unauthorized, "jwt");
        return false;
    };
    const org_id = ctx.getAttr("jwt_org") orelse {
        try json_api.err(ctx, .bad_request, "org_required");
        return false;
    };
    const uid = std.fmt.parseInt(i64, sub, 10) catch {
        try json_api.err(ctx, .unauthorized, "jwt");
        return false;
    };
    const role = try org_service.membershipRole(st.db, ctx.allocator, uid, org_id) orelse {
        try json_api.err(ctx, .forbidden, "not_a_member");
        return false;
    };
    defer ctx.allocator.free(role);
    try ctx.setAttr("jwt_role", role);
    return true;
}

pub const orgMemberInterceptor = zfinal.Interceptor{
    .name = "saas_org_member",
    .before_ud = orgMemberBefore,
};

// ── Global rate limiting (P0) ────────────────────────────────────────────────

/// Per-IP rate limiter; initialized in main before app.start().
pub var rate_limiter: zfinal.RateLimitHandler = undefined;

fn rateLimitBefore(ctx: *zfinal.Context, _: ?*anyopaque) !bool {
    rate_limiter.handle(ctx) catch |e| {
        if (e == error.TooManyRequests) {
            zfinal.auditLog(.rate_limited, ctx.req.head.target, "");
            try json_api.err(ctx, .too_many_requests, "rate_limited");
            return false;
        }
        // Fail-open on allocation errors — never 500 the whole API for a limiter.
        return true;
    };
    return true;
}

pub fn createRateLimitInterceptor() zfinal.Interceptor {
    return .{
        .name = "saas_rate_limit",
        .before_ud = rateLimitBefore,
    };
}
