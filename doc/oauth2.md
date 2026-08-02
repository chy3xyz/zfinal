# OAuth2Client

RFC 6749 helpers + **PKCE (RFC 7636)** over `HttpClient`.

```zig
var oauth = try zfinal.OAuth2Client.init(a, client_id, secret, authorize_url, token_url, redirect_uri);
defer oauth.deinit();
oauth.auth_style = .basic; // optional: HTTP Basic at token endpoint

const verifier = try zfinal.OAuth2Client.generateCodeVerifier(a);
defer a.free(verifier);
const challenge = try zfinal.OAuth2Client.challengeS256(a, verifier);
defer a.free(challenge);

const url = try oauth.buildAuthorizeUrlOpts(.{
    .scope = "openid",
    .state = "xyz",
    .code_challenge = challenge,
});
defer a.free(url);

var tok = try oauth.exchangeCodePkce(code, verifier);
defer tok.deinit();
```

**Offline / unit tests:** set `oauth.mock_token_json` (+ optional `mock_token_status`) to skip HTTP
and exercise `exchangeCode` / `exchangeCodePkce` / error paths without a live IdP.

Token JSON non-string fields → `error.InvalidTokenJson` (no panic).  
Non-2xx token responses → `error.TokenEndpointError` after parsing `error` / `error_description`.

See [progressive_architecture.md](progressive_architecture.md) (wrap with CircuitBreaker).

Demo: `zig build run-oauth2` (prints PKCE authorize URL; no live IdP).
