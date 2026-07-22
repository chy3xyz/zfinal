//! HS256 JWT (RFC 7519) — production auth building block.
//! Rejects `alg=none`. Supports nbf/iss/aud + dual-secret rotation.
//! No third-party deps; uses `std.crypto.auth.hmac.sha2.HmacSha256`.

const std = @import("std");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const JwtError = error{
    InvalidToken,
    InvalidSignature,
    TokenExpired,
    TokenNotYetValid,
    MissingClaim,
    InvalidIssuer,
    InvalidAudience,
    UnsupportedAlgorithm,
    OutOfMemory,
    WriteFailed,
};

pub const Claims = struct {
    /// Subject (user id / principal).
    sub: []const u8,
    /// Expiry as Unix seconds.
    exp: i64,
    /// Issued-at Unix seconds (optional; 0 = omit from payload).
    iat: i64 = 0,
    /// Not-before Unix seconds (optional; 0 = omit).
    nbf: i64 = 0,
    /// Issuer (optional).
    iss: ?[]const u8 = null,
    /// Audience (optional).
    aud: ?[]const u8 = null,
    /// Arbitrary role / scope string (optional).
    role: ?[]const u8 = null,
};

/// Verification policy. Pass to `verifyWithOptions`.
pub const VerifyOptions = struct {
    /// Clock skew leeway in seconds for exp/nbf.
    leeway_sec: i64 = 0,
    /// When set, payload `iss` must match.
    expected_iss: ?[]const u8 = null,
    /// When set, payload `aud` must match.
    expected_aud: ?[]const u8 = null,
    /// Optional secondary HMAC secret for key rotation (try after primary).
    previous_secret: ?[]const u8 = null,
};

/// Sign HS256 JWT. Caller owns returned slice.
pub fn sign(allocator: std.mem.Allocator, secret: []const u8, claims: Claims) JwtError![]u8 {
    const header_json = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const header_b64 = try base64UrlEncode(allocator, header_json);
    defer allocator.free(header_b64);

    var payload_buf: std.Io.Writer.Allocating = .init(allocator);
    defer payload_buf.deinit();
    const w = &payload_buf.writer;
    try w.writeAll("{\"sub\":\"");
    try writeJsonEscaped(w, claims.sub);
    try w.print("\",\"exp\":{d}", .{claims.exp});
    if (claims.iat != 0) try w.print(",\"iat\":{d}", .{claims.iat});
    if (claims.nbf != 0) try w.print(",\"nbf\":{d}", .{claims.nbf});
    if (claims.iss) |iss| {
        try w.writeAll(",\"iss\":\"");
        try writeJsonEscaped(w, iss);
        try w.writeAll("\"");
    }
    if (claims.aud) |aud| {
        try w.writeAll(",\"aud\":\"");
        try writeJsonEscaped(w, aud);
        try w.writeAll("\"");
    }
    if (claims.role) |role| {
        try w.writeAll(",\"role\":\"");
        try writeJsonEscaped(w, role);
        try w.writeAll("\"");
    }
    try w.writeAll("}");
    const payload = try payload_buf.toOwnedSlice();
    defer allocator.free(payload);

    const payload_b64 = try base64UrlEncode(allocator, payload);
    defer allocator.free(payload_b64);

    const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, payload_b64 });
    defer allocator.free(signing_input);

    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, signing_input, secret);
    const sig_b64 = try base64UrlEncode(allocator, &mac);
    defer allocator.free(sig_b64);

    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ signing_input, sig_b64 });
}

/// Verify with default options (exp only + reject alg=none).
pub fn verify(
    allocator: std.mem.Allocator,
    secret: []const u8,
    token: []const u8,
    now_unix: i64,
) JwtError!Claims {
    return verifyWithOptions(allocator, secret, token, now_unix, .{});
}

/// Verify signature + time/issuer/audience claims.
pub fn verifyWithOptions(
    allocator: std.mem.Allocator,
    secret: []const u8,
    token: []const u8,
    now_unix: i64,
    opts: VerifyOptions,
) JwtError!Claims {
    var parts = std.mem.splitScalar(u8, token, '.');
    const header_b64 = parts.next() orelse return error.InvalidToken;
    const payload_b64 = parts.next() orelse return error.InvalidToken;
    const sig_b64 = parts.next() orelse return error.InvalidToken;
    if (parts.next() != null) return error.InvalidToken;

    const header = base64UrlDecode(allocator, header_b64) catch return error.InvalidToken;
    defer allocator.free(header);
    try rejectBadAlg(header);

    const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, payload_b64 });
    defer allocator.free(signing_input);

    const sig = base64UrlDecode(allocator, sig_b64) catch return error.InvalidToken;
    defer allocator.free(sig);
    if (sig.len != HmacSha256.mac_length) return error.InvalidSignature;

    var sig_arr: [HmacSha256.mac_length]u8 = undefined;
    @memcpy(&sig_arr, sig[0..HmacSha256.mac_length]);

    if (!macOk(signing_input, secret, sig_arr)) {
        if (opts.previous_secret) |prev| {
            if (!macOk(signing_input, prev, sig_arr)) return error.InvalidSignature;
        } else {
            return error.InvalidSignature;
        }
    }

    const payload = base64UrlDecode(allocator, payload_b64) catch return error.InvalidToken;
    defer allocator.free(payload);

    const exp = parseJsonIntField(payload, "exp") orelse return error.MissingClaim;
    if (now_unix >= exp + opts.leeway_sec) return error.TokenExpired;

    if (parseJsonIntField(payload, "nbf")) |nbf| {
        if (now_unix + opts.leeway_sec < nbf) return error.TokenNotYetValid;
    }

    if (opts.expected_iss) |want_iss| {
        const got = parseJsonStringField(allocator, payload, "iss") catch return error.OutOfMemory;
        defer if (got) |g| allocator.free(g);
        if (got == null or !std.mem.eql(u8, got.?, want_iss)) return error.InvalidIssuer;
    }
    if (opts.expected_aud) |want_aud| {
        const got = parseJsonStringField(allocator, payload, "aud") catch return error.OutOfMemory;
        defer if (got) |g| allocator.free(g);
        if (got == null or !std.mem.eql(u8, got.?, want_aud)) return error.InvalidAudience;
    }

    const sub = parseJsonStringField(allocator, payload, "sub") catch return error.OutOfMemory;
    const sub_owned = sub orelse return error.MissingClaim;
    errdefer allocator.free(sub_owned);
    const role = parseJsonStringField(allocator, payload, "role") catch return error.OutOfMemory;
    errdefer if (role) |r| allocator.free(r);
    const iss = parseJsonStringField(allocator, payload, "iss") catch return error.OutOfMemory;
    errdefer if (iss) |i| allocator.free(i);
    const aud = parseJsonStringField(allocator, payload, "aud") catch return error.OutOfMemory;
    errdefer if (aud) |a| allocator.free(a);
    const iat = parseJsonIntField(payload, "iat") orelse 0;
    const nbf = parseJsonIntField(payload, "nbf") orelse 0;

    return .{
        .sub = sub_owned,
        .exp = exp,
        .iat = iat,
        .nbf = nbf,
        .iss = iss,
        .aud = aud,
        .role = role,
    };
}

pub fn freeClaims(allocator: std.mem.Allocator, claims: Claims) void {
    allocator.free(claims.sub);
    if (claims.role) |r| allocator.free(r);
    if (claims.iss) |i| allocator.free(i);
    if (claims.aud) |a| allocator.free(a);
}

fn macOk(signing_input: []const u8, secret: []const u8, sig_arr: [HmacSha256.mac_length]u8) bool {
    var expected: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&expected, signing_input, secret);
    return std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, expected, sig_arr);
}

fn rejectBadAlg(header_json: []const u8) JwtError!void {
    // Reject explicit none / missing HS256.
    if (std.mem.indexOf(u8, header_json, "\"alg\":\"none\"") != null or
        std.mem.indexOf(u8, header_json, "\"alg\": \"none\"") != null)
    {
        return error.UnsupportedAlgorithm;
    }
    if (std.mem.indexOf(u8, header_json, "HS256") == null) {
        return error.UnsupportedAlgorithm;
    }
}

fn writeJsonEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            else => try w.writeByte(c),
        }
    }
}

fn base64UrlEncode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const len = enc.calcSize(data.len);
    const out = try allocator.alloc(u8, len);
    _ = enc.encode(out, data);
    return out;
}

fn base64UrlDecode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const dec = std.base64.url_safe_no_pad.Decoder;
    const len = try dec.calcSizeForSlice(data);
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    try dec.decode(out, data);
    return out;
}

fn parseJsonIntField(json: []const u8, key: []const u8) ?i64 {
    var key_buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, json, pat) orelse return null;
    var i = idx + pat.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}
    const start = i;
    if (i < json.len and json[i] == '-') i += 1;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) {}
    if (i == start or (i == start + 1 and json[start] == '-')) return null;
    return std.fmt.parseInt(i64, json[start..i], 10) catch null;
}

fn parseJsonStringField(allocator: std.mem.Allocator, json: []const u8, key: []const u8) !?[]u8 {
    var key_buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&key_buf, "\"{s}\":\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, json, pat) orelse return null;
    var i = idx + pat.len;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    while (i < json.len) : (i += 1) {
        if (json[i] == '\\' and i + 1 < json.len) {
            try out.append(allocator, json[i + 1]);
            i += 1;
            continue;
        }
        if (json[i] == '"') break;
        try out.append(allocator, json[i]);
    }
    return try out.toOwnedSlice(allocator);
}

test "jwt: sign and verify roundtrip" {
    const allocator = std.testing.allocator;
    const secret = "test-secret-key-32bytes-minimum!!";
    const now: i64 = 1_700_000_000;
    const token = try sign(allocator, secret, .{
        .sub = "user-42",
        .exp = now + 3600,
        .iat = now,
        .nbf = now - 10,
        .iss = "zfinal",
        .aud = "api",
        .role = "admin",
    });
    defer allocator.free(token);

    const claims = try verifyWithOptions(allocator, secret, token, now, .{
        .expected_iss = "zfinal",
        .expected_aud = "api",
    });
    defer freeClaims(allocator, claims);
    try std.testing.expectEqualStrings("user-42", claims.sub);
    try std.testing.expectEqualStrings("admin", claims.role.?);
    try std.testing.expectEqualStrings("zfinal", claims.iss.?);
    try std.testing.expectError(error.TokenExpired, verify(allocator, secret, token, now + 4000));
    try std.testing.expectError(error.TokenNotYetValid, verify(allocator, secret, token, now - 100));
}

test "jwt: rejects tampered token and alg none" {
    const allocator = std.testing.allocator;
    const secret = "test-secret-key-32bytes-minimum!!";
    const now: i64 = 1_700_000_000;
    const token = try sign(allocator, secret, .{ .sub = "u", .exp = now + 60 });
    defer allocator.free(token);
    var buf = try allocator.dupe(u8, token);
    defer allocator.free(buf);
    if (buf.len > 5) {
        const i = buf.len - 3;
        buf[i] = if (buf[i] == 'A') 'B' else 'A';
    }
    try std.testing.expectError(error.InvalidSignature, verify(allocator, secret, buf, now));

    // alg=none forged header
    const none_hdr = try base64UrlEncode(allocator, "{\"alg\":\"none\",\"typ\":\"JWT\"}");
    defer allocator.free(none_hdr);
    const forged = try std.fmt.allocPrint(allocator, "{s}.e30.x", .{none_hdr});
    defer allocator.free(forged);
    try std.testing.expectError(error.UnsupportedAlgorithm, verify(allocator, secret, forged, now));
}

test "jwt: previous_secret rotation" {
    const allocator = std.testing.allocator;
    const old_sec = "old-secret-key-32bytes-minimum!!!";
    const new_sec = "new-secret-key-32bytes-minimum!!!";
    const now: i64 = 1_700_000_000;
    const token = try sign(allocator, old_sec, .{ .sub = "u", .exp = now + 60 });
    defer allocator.free(token);
    const claims = try verifyWithOptions(allocator, new_sec, token, now, .{ .previous_secret = old_sec });
    defer freeClaims(allocator, claims);
    try std.testing.expectEqualStrings("u", claims.sub);
}
