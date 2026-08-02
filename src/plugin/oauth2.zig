const std = @import("std");
const HttpClient = @import("http_client.zig").HttpClient;
const RandomKit = @import("../kit/random_kit.zig").RandomKit;

/// OAuth2 Authorization Code + Client Credentials helpers (RFC 6749 + PKCE RFC 7636).
pub const OAuth2Client = struct {
    allocator: std.mem.Allocator,
    client_id: []const u8,
    client_secret: []const u8,
    authorize_url: []const u8,
    token_url: []const u8,
    redirect_uri: []const u8,
    http: HttpClient,
    /// How to authenticate at the token endpoint.
    auth_style: AuthStyle = .body,

    pub const AuthStyle = enum {
        /// `client_id` + `client_secret` in form body (default).
        body,
        /// HTTP Basic `client_id:client_secret`.
        basic,
    };

    pub const TokenResponse = struct {
        access_token: []const u8,
        token_type: []const u8 = "Bearer",
        expires_in: ?u64 = null,
        refresh_token: ?[]const u8 = null,
        scope: ?[]const u8 = null,
        arena: std.heap.ArenaAllocator,

        pub fn deinit(self: *TokenResponse) void {
            self.arena.deinit();
        }
    };

    pub const AuthorizeOpts = struct {
        scope: ?[]const u8 = null,
        state: ?[]const u8 = null,
        code_challenge: ?[]const u8 = null,
        code_challenge_method: []const u8 = "S256",
    };

    pub fn init(
        allocator: std.mem.Allocator,
        client_id: []const u8,
        client_secret: []const u8,
        authorize_url: []const u8,
        token_url: []const u8,
        redirect_uri: []const u8,
    ) !OAuth2Client {
        return .{
            .allocator = allocator,
            .client_id = try allocator.dupe(u8, client_id),
            .client_secret = try allocator.dupe(u8, client_secret),
            .authorize_url = try allocator.dupe(u8, authorize_url),
            .token_url = try allocator.dupe(u8, token_url),
            .redirect_uri = try allocator.dupe(u8, redirect_uri),
            .http = try HttpClient.init(allocator, ""),
        };
    }

    pub fn deinit(self: *OAuth2Client) void {
        self.http.deinit();
        self.allocator.free(self.client_id);
        self.allocator.free(self.client_secret);
        self.allocator.free(self.authorize_url);
        self.allocator.free(self.token_url);
        self.allocator.free(self.redirect_uri);
    }

    /// Cryptographically random `code_verifier` (BASE64URL, no pad). Caller frees.
    pub fn generateCodeVerifier(allocator: std.mem.Allocator) ![]u8 {
        var raw: [32]u8 = undefined;
        RandomKit.randomBytes(&raw);
        var out: [64]u8 = undefined;
        const n = std.base64.url_safe_no_pad.Encoder.calcSize(raw.len);
        _ = std.base64.url_safe_no_pad.Encoder.encode(out[0..n], &raw);
        return try allocator.dupe(u8, out[0..n]);
    }

    /// S256 `code_challenge` = BASE64URL(SHA256(verifier)). Caller frees.
    pub fn challengeS256(allocator: std.mem.Allocator, verifier: []const u8) ![]u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(verifier, &hash, .{});
        var out: [64]u8 = undefined;
        const n = std.base64.url_safe_no_pad.Encoder.calcSize(hash.len);
        _ = std.base64.url_safe_no_pad.Encoder.encode(out[0..n], &hash);
        return try allocator.dupe(u8, out[0..n]);
    }

    pub fn buildAuthorizeUrl(self: *OAuth2Client, scope: ?[]const u8, state: ?[]const u8) ![]u8 {
        return self.buildAuthorizeUrlOpts(.{ .scope = scope, .state = state });
    }

    pub fn buildAuthorizeUrlOpts(self: *OAuth2Client, opts: AuthorizeOpts) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(self.allocator);
        try list.appendSlice(self.allocator, self.authorize_url);
        try list.appendSlice(self.allocator, "?response_type=code");
        try list.appendSlice(self.allocator, "&client_id=");
        try appendEncoded(&list, self.allocator, self.client_id);
        try list.appendSlice(self.allocator, "&redirect_uri=");
        try appendEncoded(&list, self.allocator, self.redirect_uri);
        if (opts.scope) |s| {
            try list.appendSlice(self.allocator, "&scope=");
            try appendEncoded(&list, self.allocator, s);
        }
        if (opts.state) |st| {
            try list.appendSlice(self.allocator, "&state=");
            try appendEncoded(&list, self.allocator, st);
        }
        if (opts.code_challenge) |cc| {
            try list.appendSlice(self.allocator, "&code_challenge=");
            try appendEncoded(&list, self.allocator, cc);
            try list.appendSlice(self.allocator, "&code_challenge_method=");
            try appendEncoded(&list, self.allocator, opts.code_challenge_method);
        }
        return try list.toOwnedSlice(self.allocator);
    }

    pub fn exchangeCode(self: *OAuth2Client, code: []const u8) !TokenResponse {
        return self.exchangeCodePkce(code, null);
    }

    pub fn exchangeCodePkce(self: *OAuth2Client, code: []const u8, code_verifier: ?[]const u8) !TokenResponse {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);
        try body.appendSlice(self.allocator, "grant_type=authorization_code");
        try body.appendSlice(self.allocator, "&code=");
        try appendEncoded(&body, self.allocator, code);
        try body.appendSlice(self.allocator, "&redirect_uri=");
        try appendEncoded(&body, self.allocator, self.redirect_uri);
        try self.appendClientAuth(&body);
        if (code_verifier) |cv| {
            try body.appendSlice(self.allocator, "&code_verifier=");
            try appendEncoded(&body, self.allocator, cv);
        }
        return try self.postToken(body.items);
    }

    pub fn clientCredentials(self: *OAuth2Client, scope: ?[]const u8) !TokenResponse {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);
        try body.appendSlice(self.allocator, "grant_type=client_credentials");
        try self.appendClientAuth(&body);
        if (scope) |s| {
            try body.appendSlice(self.allocator, "&scope=");
            try appendEncoded(&body, self.allocator, s);
        }
        return try self.postToken(body.items);
    }

    pub fn refresh(self: *OAuth2Client, refresh_token: []const u8) !TokenResponse {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);
        try body.appendSlice(self.allocator, "grant_type=refresh_token");
        try body.appendSlice(self.allocator, "&refresh_token=");
        try appendEncoded(&body, self.allocator, refresh_token);
        try self.appendClientAuth(&body);
        return try self.postToken(body.items);
    }

    fn appendClientAuth(self: *OAuth2Client, body: *std.ArrayList(u8)) !void {
        try body.appendSlice(self.allocator, "&client_id=");
        try appendEncoded(body, self.allocator, self.client_id);
        if (self.auth_style == .body) {
            try body.appendSlice(self.allocator, "&client_secret=");
            try appendEncoded(body, self.allocator, self.client_secret);
        }
    }

    fn postToken(self: *OAuth2Client, body: []const u8) !TokenResponse {
        if (self.auth_style == .basic) {
            const raw = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ self.client_id, self.client_secret });
            defer self.allocator.free(raw);
            const enc_len = std.base64.standard.Encoder.calcSize(raw.len);
            const enc = try self.allocator.alloc(u8, enc_len);
            defer self.allocator.free(enc);
            _ = std.base64.standard.Encoder.encode(enc, raw);
            const auth = try std.fmt.allocPrint(self.allocator, "Basic {s}", .{enc});
            defer self.allocator.free(auth);
            const headers = [_]std.http.Header{
                .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
                .{ .name = "authorization", .value = auth },
            };
            const res = try self.http.requestWith(.POST, self.token_url, body, &headers);
            defer {
                var r = res;
                r.deinit();
            }
            if (res.status < 200 or res.status >= 300) {
                var te = try OAuth2Client.parseTokenError(self.allocator, res.body);
                defer te.arena.deinit();
                return error.TokenEndpointError;
            }
            return try parseTokenResponse(self.allocator, res.body);
        }

        const res = try self.http.postForm(self.token_url, body);
        defer {
            var r = res;
            r.deinit();
        }
        if (res.status < 200 or res.status >= 300) {
            var te = try OAuth2Client.parseTokenError(self.allocator, res.body);
            defer te.arena.deinit();
            return error.TokenEndpointError;
        }
        return try parseTokenResponse(self.allocator, res.body);
    }

    /// Parse OAuth error JSON (`error` / `error_description`). Caller owns; free via arena.deinit.
    pub fn parseTokenError(allocator: std.mem.Allocator, json_body: []const u8) !struct { code: []const u8, description: []const u8, arena: std.heap.ArenaAllocator } {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();
        const parsed = std.json.parseFromSlice(std.json.Value, aa, json_body, .{}) catch {
            return .{ .code = "unknown", .description = try aa.dupe(u8, json_body), .arena = arena };
        };
        if (parsed.value != .object) {
            return .{ .code = "unknown", .description = try aa.dupe(u8, json_body), .arena = arena };
        }
        const obj = parsed.value.object;
        const code = try jsonString(obj.get("error"), aa) orelse "unknown";
        const desc = try jsonString(obj.get("error_description"), aa) orelse "";
        return .{ .code = code, .description = desc, .arena = arena };
    }

    pub fn parseTokenResponse(allocator: std.mem.Allocator, json_body: []const u8) !TokenResponse {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();

        const parsed = try std.json.parseFromSlice(std.json.Value, aa, json_body, .{});
        if (parsed.value != .object) return error.InvalidTokenJson;
        const obj = parsed.value.object;

        const access_token = try jsonString(obj.get("access_token"), aa) orelse return error.MissingAccessToken;
        const token_type = try jsonString(obj.get("token_type"), aa) orelse "Bearer";

        var expires_in: ?u64 = null;
        if (obj.get("expires_in")) |e| {
            expires_in = switch (e) {
                .integer => |i| if (i < 0) null else @intCast(i),
                .float => |f| if (f < 0) null else @intFromFloat(f),
                else => null,
            };
        }

        const refresh_token = try jsonString(obj.get("refresh_token"), aa);
        const scope = try jsonString(obj.get("scope"), aa);

        return .{
            .access_token = access_token,
            .token_type = token_type,
            .expires_in = expires_in,
            .refresh_token = refresh_token,
            .scope = scope,
            .arena = arena,
        };
    }
};

fn jsonString(v: ?std.json.Value, allocator: std.mem.Allocator) !?[]const u8 {
    const x = v orelse return null;
    return switch (x) {
        .string => |s| try allocator.dupe(u8, s),
        else => error.InvalidTokenJson,
    };
}

fn appendEncoded(list: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try list.append(allocator, c),
            ' ' => try list.appendSlice(allocator, "+"),
            else => {
                var buf: [3]u8 = undefined;
                const enc = try std.fmt.bufPrint(&buf, "%{X:0>2}", .{c});
                try list.appendSlice(allocator, enc);
            },
        }
    }
}

test "oauth2: build authorize url" {
    const a = std.testing.allocator;
    var oauth = try OAuth2Client.init(
        a,
        "cid",
        "secret",
        "https://auth.example/authorize",
        "https://auth.example/token",
        "https://app.example/cb",
    );
    defer oauth.deinit();
    const url = try oauth.buildAuthorizeUrl("openid profile", "xyz");
    defer a.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "client_id=cid") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "state=xyz") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "response_type=code") != null);
}

test "oauth2: PKCE authorize url and challenge" {
    const a = std.testing.allocator;
    var oauth = try OAuth2Client.init(a, "cid", "sec", "https://a/x", "https://a/t", "https://app/cb");
    defer oauth.deinit();
    const verifier = try OAuth2Client.generateCodeVerifier(a);
    defer a.free(verifier);
    const challenge = try OAuth2Client.challengeS256(a, verifier);
    defer a.free(challenge);
    try std.testing.expect(verifier.len >= 43);
    const url = try oauth.buildAuthorizeUrlOpts(.{ .state = "s", .code_challenge = challenge });
    defer a.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge=") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
}

test "oauth2: parse token json" {
    const a = std.testing.allocator;
    const json =
        \\{"access_token":"tok","token_type":"Bearer","expires_in":3600,"refresh_token":"ref"}
    ;
    var tok = try OAuth2Client.parseTokenResponse(a, json);
    defer tok.deinit();
    try std.testing.expectEqualStrings("tok", tok.access_token);
    try std.testing.expectEqual(@as(u64, 3600), tok.expires_in.?);
    try std.testing.expectEqualStrings("ref", tok.refresh_token.?);
}

test "oauth2: parseTokenResponse rejects non-string access_token" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidTokenJson, OAuth2Client.parseTokenResponse(a, "{\"access_token\":1}"));
}

test "oauth2: parseTokenError extracts fields" {
    const a = std.testing.allocator;
    var err = try OAuth2Client.parseTokenError(a, "{\"error\":\"invalid_grant\",\"error_description\":\"bad code\"}");
    defer err.arena.deinit();
    try std.testing.expectEqualStrings("invalid_grant", err.code);
    try std.testing.expectEqualStrings("bad code", err.description);
}
