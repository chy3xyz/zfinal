//! OAuth2 helpers demo — PKCE offline by default; optional live token exchange.
//!
//! ```
//! zig build run-oauth2
//! # live client_credentials:
//! OAUTH2_LIVE=1 OAUTH2_TOKEN_URL=… OAUTH2_CLIENT_ID=… OAUTH2_CLIENT_SECRET=… zig build run-oauth2
//! ```

const std = @import("std");
const zfinal = @import("zfinal");

pub fn main(init: std.process.Init) !void {
    zfinal.io_instance.init(init);
    const a = init.gpa;

    const client_id = if (std.c.getenv("OAUTH2_CLIENT_ID")) |p| std.mem.span(p) else "demo-client";
    const client_secret = if (std.c.getenv("OAUTH2_CLIENT_SECRET")) |p| std.mem.span(p) else "demo-secret";
    const authorize_url = if (std.c.getenv("OAUTH2_AUTHORIZE_URL")) |p| std.mem.span(p) else "https://auth.example/authorize";
    const token_url = if (std.c.getenv("OAUTH2_TOKEN_URL")) |p| std.mem.span(p) else "https://auth.example/token";
    const redirect_uri = if (std.c.getenv("OAUTH2_REDIRECT_URI")) |p| std.mem.span(p) else "https://app.example/callback";

    var oauth = try zfinal.OAuth2Client.init(a, client_id, client_secret, authorize_url, token_url, redirect_uri);
    defer oauth.deinit();
    oauth.auth_style = .basic;
    if (std.c.getenv("OAUTH2_AUTH_STYLE")) |s| {
        if (std.mem.eql(u8, std.mem.span(s), "body")) oauth.auth_style = .body;
    }

    const verifier = try zfinal.OAuth2Client.generateCodeVerifier(a);
    defer a.free(verifier);
    const challenge = try zfinal.OAuth2Client.challengeS256(a, verifier);
    defer a.free(challenge);

    const url = try oauth.buildAuthorizeUrlOpts(.{
        .scope = "openid profile",
        .state = "demo-state",
        .code_challenge = challenge,
    });
    defer a.free(url);

    std.debug.print("PKCE verifier (store server-side): {s}\n", .{verifier});
    std.debug.print("authorize URL:\n{s}\n", .{url});

    // Parse happy-path token JSON (offline)
    var tok = try zfinal.OAuth2Client.parseTokenResponse(a,
        \\{"access_token":"at","token_type":"Bearer","expires_in":3600,"refresh_token":"rt"}
    );
    defer tok.deinit();
    std.debug.print("parsed access_token={s} expires_in={d}\n", .{ tok.access_token, tok.expires_in.? });

    if (std.c.getenv("OAUTH2_LIVE") != null) {
        const scope = if (std.c.getenv("OAUTH2_SCOPE")) |p| std.mem.span(p) else null;
        var live = try oauth.clientCredentials(scope);
        defer live.deinit();
        std.debug.print("LIVE client_credentials access_token len={d} type={s}\n", .{ live.access_token.len, live.token_type });
    } else {
        std.debug.print("tip: set OAUTH2_LIVE=1 + OAUTH2_TOKEN_URL/CLIENT_ID/SECRET for live exchange\n", .{});
    }
}
