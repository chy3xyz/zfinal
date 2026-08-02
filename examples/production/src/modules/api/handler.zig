//! Production API handlers — State + extract (smart_routing).
const std = @import("std");
const zfinal = @import("zfinal");

/// Typed app State injected via `app.setState(AppState, &…)`.
pub const AppState = struct {
    token_mgr: *zfinal.TokenManager,
    jwt_secret: []const u8,
    jwt_secret_prev: ?[]const u8 = null,
    jwt_iss: ?[]const u8 = null,
    jwt_aud: ?[]const u8 = null,
    /// L3 demo: in-process outbox + bus (swap NatsBus/RobustMQBus + DbOutbox in real deploy).
    outbox: *zfinal.MemoryOutbox = undefined,
    bus: zfinal.Bus = undefined,
};

pub fn form(ctx: *zfinal.Context) !void {
    const st = try ctx.state(AppState);
    const token = try st.token_mgr.generate();
    defer ctx.allocator.free(token);

    var html_buf: [2048]u8 = undefined;
    const html = try std.fmt.bufPrint(&html_buf,
        \\<html><body>
        \\<h1>ZFinal Production</h1>
\\<p>Health: /health</p>
\\<p>WS: /ws · Drain: POST /internal/outbox/drain (JWT)</p>
\\<form method="POST" action="/api/submit">
        \\  <input type="hidden" name="_token" value="{s}">
        \\  <input name="message" placeholder="message" required>
        \\  <button type="submit">Submit</button>
        \\</form>
        \\</body></html>
    , .{token});
    try ctx.renderHtml(html);
}

pub fn submit(ctx: *zfinal.Context) !void {
    const st = try ctx.state(AppState);
    const msg = try zfinal.extract.optionalQuery(ctx, "message") orelse "";
    // Same-request outbox intent (demo). Production: append inside DB transaction → DbOutbox.
    const idem = try std.fmt.allocPrint(ctx.allocator, "submit-{d}", .{zfinal.TimeKit.nowMillis()});
    defer ctx.allocator.free(idem);
    try st.outbox.port().append(ctx.allocator, "form.submitted", msg, idem);
    try ctx.renderJson(.{ .ok = true, .received = msg, .outbox_pending = st.outbox.len() });
}

pub fn drainOutbox(ctx: *zfinal.Context) !void {
    const st = try ctx.state(AppState);
    const stats = try st.outbox.drainOnce(st.bus);
    try ctx.renderJson(.{
        .ok = true,
        .published = stats.published,
        .failed = stats.failed,
        .pending = st.outbox.len(),
    });
}

pub fn issueToken(ctx: *zfinal.Context) !void {
    const st = try ctx.state(AppState);
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const now: i64 = @intCast(ts.sec);
    const token = try zfinal.jwtSign(ctx.allocator, st.jwt_secret, .{
        .sub = "demo-user",
        .exp = now + 3600,
        .iat = now,
        .iss = st.jwt_iss,
        .aud = st.jwt_aud,
        .role = "user",
    });
    defer ctx.allocator.free(token);
    try ctx.renderJson(.{ .token = token, .token_type = "Bearer", .expires_in = 3600 });
}

pub fn me(ctx: *zfinal.Context) !void {
    const jwt = ctx.ext(zfinal.extension.JwtIdentity);
    const sub = if (jwt) |j| j.sub else ctx.getAttr("jwt_sub") orelse "unknown";
    const role = if (jwt) |j| j.role else ctx.getAttr("jwt_role") orelse "";
    const request_id = if (ctx.ext(zfinal.extension.RequestId)) |r|
        r.value
    else
        ctx.getAttr("request_id") orelse "";
    try ctx.renderJson(.{ .sub = sub, .role = role, .request_id = request_id });
}
