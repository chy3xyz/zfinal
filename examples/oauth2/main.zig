//! Offline OAuth2 helpers demo — PKCE authorize URL (no live IdP required).
//!
//! ```
//! zig build run-oauth2
//! ```

const std = @import("std");
const zfinal = @import("zfinal");

pub fn main(init: std.process.Init) !void {
    zfinal.io_instance.init(init);
    const a = init.gpa;

    var oauth = try zfinal.OAuth2Client.init(
        a,
        "demo-client",
        "demo-secret",
        "https://auth.example/authorize",
        "https://auth.example/token",
        "https://app.example/callback",
    );
    defer oauth.deinit();
    oauth.auth_style = .basic;

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
    std.debug.print("Authorize URL:\n{s}\n", .{url});

    // Parse happy-path token JSON (offline)
    var tok = try zfinal.OAuth2Client.parseTokenResponse(a,
        \\{"access_token":"at","token_type":"Bearer","expires_in":3600,"refresh_token":"rt"}
    );
    defer tok.deinit();
    std.debug.print("parsed access_token={s} expires_in={d}\n", .{ tok.access_token, tok.expires_in.? });
}
