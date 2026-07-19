const std = @import("std");
const HttpClient = @import("http_client.zig").HttpClient;

/// OAuth2 Authorization Code + Client Credentials helpers (RFC 6749).
/// Builds authorize URLs and exchanges tokens via the token endpoint.
pub const OAuth2Client = struct {
    allocator: std.mem.Allocator,
    client_id: []const u8,
    client_secret: []const u8,
    authorize_url: []const u8,
    token_url: []const u8,
    redirect_uri: []const u8,
    http: HttpClient,

    pub const TokenResponse = struct {
        access_token: []const u8,
        token_type: []const u8 = "Bearer",
        expires_in: ?u64 = null,
        refresh_token: ?[]const u8 = null,
        scope: ?[]const u8 = null,
        /// Owned heap buffers freed by `deinit`.
        arena: std.heap.ArenaAllocator,

        pub fn deinit(self: *TokenResponse) void {
            self.arena.deinit();
        }
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

    /// Build `authorize_url?response_type=code&client_id=...&redirect_uri=...&scope=...&state=...`
    pub fn buildAuthorizeUrl(self: *OAuth2Client, scope: ?[]const u8, state: ?[]const u8) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(self.allocator);
        try list.appendSlice(self.allocator, self.authorize_url);
        try list.appendSlice(self.allocator, "?response_type=code");
        try list.appendSlice(self.allocator, "&client_id=");
        try appendEncoded(&list, self.allocator, self.client_id);
        try list.appendSlice(self.allocator, "&redirect_uri=");
        try appendEncoded(&list, self.allocator, self.redirect_uri);
        if (scope) |s| {
            try list.appendSlice(self.allocator, "&scope=");
            try appendEncoded(&list, self.allocator, s);
        }
        if (state) |st| {
            try list.appendSlice(self.allocator, "&state=");
            try appendEncoded(&list, self.allocator, st);
        }
        return try list.toOwnedSlice(self.allocator);
    }

    pub fn exchangeCode(self: *OAuth2Client, code: []const u8) !TokenResponse {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);
        try body.appendSlice(self.allocator, "grant_type=authorization_code");
        try body.appendSlice(self.allocator, "&code=");
        try appendEncoded(&body, self.allocator, code);
        try body.appendSlice(self.allocator, "&redirect_uri=");
        try appendEncoded(&body, self.allocator, self.redirect_uri);
        try body.appendSlice(self.allocator, "&client_id=");
        try appendEncoded(&body, self.allocator, self.client_id);
        try body.appendSlice(self.allocator, "&client_secret=");
        try appendEncoded(&body, self.allocator, self.client_secret);
        return try self.postToken(body.items);
    }

    pub fn clientCredentials(self: *OAuth2Client, scope: ?[]const u8) !TokenResponse {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);
        try body.appendSlice(self.allocator, "grant_type=client_credentials");
        try body.appendSlice(self.allocator, "&client_id=");
        try appendEncoded(&body, self.allocator, self.client_id);
        try body.appendSlice(self.allocator, "&client_secret=");
        try appendEncoded(&body, self.allocator, self.client_secret);
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
        try body.appendSlice(self.allocator, "&client_id=");
        try appendEncoded(&body, self.allocator, self.client_id);
        try body.appendSlice(self.allocator, "&client_secret=");
        try appendEncoded(&body, self.allocator, self.client_secret);
        return try self.postToken(body.items);
    }

    fn postToken(self: *OAuth2Client, body: []const u8) !TokenResponse {
        const res = try self.http.postForm(self.token_url, body);
        defer {
            var r = res;
            r.deinit();
        }
        if (res.status < 200 or res.status >= 300) return error.TokenEndpointError;
        return try parseTokenResponse(self.allocator, res.body);
    }

    pub fn parseTokenResponse(allocator: std.mem.Allocator, json_body: []const u8) !TokenResponse {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();

        const parsed = try std.json.parseFromSlice(std.json.Value, aa, json_body, .{});
        const obj = parsed.value.object;

        const access = obj.get("access_token") orelse return error.MissingAccessToken;
        const access_token = try aa.dupe(u8, access.string);

        var token_type: []const u8 = "Bearer";
        if (obj.get("token_type")) |tt| token_type = try aa.dupe(u8, tt.string);

        var expires_in: ?u64 = null;
        if (obj.get("expires_in")) |e| {
            expires_in = switch (e) {
                .integer => |i| @intCast(i),
                .float => |f| @intFromFloat(f),
                else => null,
            };
        }

        var refresh_token: ?[]const u8 = null;
        if (obj.get("refresh_token")) |rt| refresh_token = try aa.dupe(u8, rt.string);

        var scope: ?[]const u8 = null;
        if (obj.get("scope")) |sc| scope = try aa.dupe(u8, sc.string);

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
