//! HS256 + RS256 sign/verify JWT (RFC 7519) — production auth building block.
//! Rejects `alg=none`. Supports nbf/iss/aud + dual-secret rotation (HS256).
//! RS256 sign/verify via PKCS#1 or SPKI keys (OIDC / gateway tokens).
//! No third-party deps; uses `std.crypto` HMAC-SHA256 + Certificate.rsa.

const std = @import("std");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const rsa = std.crypto.Certificate.rsa;

pub const JwtError = error{
    InvalidToken,
    InvalidSignature,
    TokenExpired,
    TokenNotYetValid,
    MissingClaim,
    InvalidIssuer,
    InvalidAudience,
    UnsupportedAlgorithm,
    InvalidPublicKey,
    InvalidPrivateKey,
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

/// Verification policy. Pass to `verifyWithOptions` / `verifyRs256`.
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

fn encodeClaimsJson(allocator: std.mem.Allocator, claims: Claims) JwtError![]u8 {
    var payload_buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer payload_buf.deinit();
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
    return payload_buf.toOwnedSlice() catch return error.OutOfMemory;
}

/// Sign HS256 JWT. Caller owns returned slice.
pub fn sign(allocator: std.mem.Allocator, secret: []const u8, claims: Claims) JwtError![]u8 {
    const header_json = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const header_b64 = try base64UrlEncode(allocator, header_json);
    defer allocator.free(header_b64);

    const payload = try encodeClaimsJson(allocator, claims);
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

/// Sign RS256 JWT with a PEM (`RSA PRIVATE KEY` / `PRIVATE KEY`) or DER PKCS#1 private key.
/// Caller owns returned slice.
pub fn signRs256(
    allocator: std.mem.Allocator,
    private_key_pem_or_der: []const u8,
    claims: Claims,
) JwtError![]u8 {
    const header_json = "{\"alg\":\"RS256\",\"typ\":\"JWT\"}";
    const header_b64 = try base64UrlEncode(allocator, header_json);
    defer allocator.free(header_b64);

    const payload = try encodeClaimsJson(allocator, claims);
    defer allocator.free(payload);

    const payload_b64 = try base64UrlEncode(allocator, payload);
    defer allocator.free(payload_b64);

    const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, payload_b64 });
    defer allocator.free(signing_input);

    const rsa_der = try loadRsaPrivateKeyDer(allocator, private_key_pem_or_der);
    defer allocator.free(rsa_der);
    const key_comps = parsePrivateKeyDer(rsa_der) catch return error.InvalidPrivateKey;

    const mod_len = key_comps.modulus.len;
    return switch (mod_len) {
        256 => try finishRs256Token(allocator, signing_input, try signRs256Fixed(
            256,
            signing_input,
            key_comps.modulus,
            key_comps.private_exponent,
        )),
        384 => try finishRs256Token(allocator, signing_input, try signRs256Fixed(
            384,
            signing_input,
            key_comps.modulus,
            key_comps.private_exponent,
        )),
        512 => try finishRs256Token(allocator, signing_input, try signRs256Fixed(
            512,
            signing_input,
            key_comps.modulus,
            key_comps.private_exponent,
        )),
        else => error.UnsupportedAlgorithm,
    };
}

fn finishRs256Token(allocator: std.mem.Allocator, signing_input: []const u8, sig: anytype) JwtError![]u8 {
    const sig_b64 = try base64UrlEncode(allocator, &sig);
    defer allocator.free(sig_b64);
    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ signing_input, sig_b64 });
}

/// Verify with default options (exp only + reject alg=none). HS256 only.
pub fn verify(
    allocator: std.mem.Allocator,
    secret: []const u8,
    token: []const u8,
    now_unix: i64,
) JwtError!Claims {
    return verifyWithOptions(allocator, secret, token, now_unix, .{});
}

/// Verify HS256 signature + time/issuer/audience claims.
pub fn verifyWithOptions(
    allocator: std.mem.Allocator,
    secret: []const u8,
    token: []const u8,
    now_unix: i64,
    opts: VerifyOptions,
) JwtError!Claims {
    const parts = try splitToken(token);
    const header = base64UrlDecode(allocator, parts.header_b64) catch return error.InvalidToken;
    defer allocator.free(header);
    try requireAlg(header, .hs256);

    const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parts.header_b64, parts.payload_b64 });
    defer allocator.free(signing_input);

    const sig = base64UrlDecode(allocator, parts.sig_b64) catch return error.InvalidToken;
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

    return try parseClaims(allocator, parts.payload_b64, now_unix, opts);
}

/// Verify RS256 JWT with a PEM (`PUBLIC KEY` / `RSA PUBLIC KEY`) or DER RSA public key.
pub fn verifyRs256(
    allocator: std.mem.Allocator,
    public_key_pem_or_der: []const u8,
    token: []const u8,
    now_unix: i64,
    opts: VerifyOptions,
) JwtError!Claims {
    const parts = try splitToken(token);
    const header = base64UrlDecode(allocator, parts.header_b64) catch return error.InvalidToken;
    defer allocator.free(header);
    try requireAlg(header, .rs256);

    const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parts.header_b64, parts.payload_b64 });
    defer allocator.free(signing_input);

    const sig = base64UrlDecode(allocator, parts.sig_b64) catch return error.InvalidToken;
    defer allocator.free(sig);

    try verifyRs256Signature(allocator, public_key_pem_or_der, signing_input, sig);
    return try parseClaims(allocator, parts.payload_b64, now_unix, opts);
}

pub fn freeClaims(allocator: std.mem.Allocator, claims: Claims) void {
    allocator.free(claims.sub);
    if (claims.role) |r| allocator.free(r);
    if (claims.iss) |i| allocator.free(i);
    if (claims.aud) |a| allocator.free(a);
}

const TokenParts = struct {
    header_b64: []const u8,
    payload_b64: []const u8,
    sig_b64: []const u8,
};

fn splitToken(token: []const u8) JwtError!TokenParts {
    var parts = std.mem.splitScalar(u8, token, '.');
    const header_b64 = parts.next() orelse return error.InvalidToken;
    const payload_b64 = parts.next() orelse return error.InvalidToken;
    const sig_b64 = parts.next() orelse return error.InvalidToken;
    if (parts.next() != null) return error.InvalidToken;
    return .{ .header_b64 = header_b64, .payload_b64 = payload_b64, .sig_b64 = sig_b64 };
}

fn parseClaims(
    allocator: std.mem.Allocator,
    payload_b64: []const u8,
    now_unix: i64,
    opts: VerifyOptions,
) JwtError!Claims {
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

fn macOk(signing_input: []const u8, secret: []const u8, sig_arr: [HmacSha256.mac_length]u8) bool {
    var expected: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&expected, signing_input, secret);
    return std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, expected, sig_arr);
}

const Alg = enum { hs256, rs256 };

fn requireAlg(header_json: []const u8, want: Alg) JwtError!void {
    if (std.mem.indexOf(u8, header_json, "\"alg\":\"none\"") != null or
        std.mem.indexOf(u8, header_json, "\"alg\": \"none\"") != null)
    {
        return error.UnsupportedAlgorithm;
    }
    const ok = switch (want) {
        .hs256 => std.mem.indexOf(u8, header_json, "HS256") != null,
        .rs256 => std.mem.indexOf(u8, header_json, "RS256") != null,
    };
    if (!ok) return error.UnsupportedAlgorithm;
}

fn verifyRs256Signature(
    allocator: std.mem.Allocator,
    public_key_pem_or_der: []const u8,
    signing_input: []const u8,
    sig: []const u8,
) JwtError!void {
    const rsa_der = try loadRsaPublicKeyDer(allocator, public_key_pem_or_der);
    defer allocator.free(rsa_der);

    const comps = rsa.PublicKey.parseDer(rsa_der) catch return error.InvalidPublicKey;
    const pk = rsa.PublicKey.fromBytes(comps.exponent, comps.modulus) catch return error.InvalidPublicKey;

    const mod_len = comps.modulus.len;
    if (sig.len != mod_len) return error.InvalidSignature;

    switch (mod_len) {
        256 => try verifyRs256Fixed(256, sig, signing_input, pk),
        384 => try verifyRs256Fixed(384, sig, signing_input, pk),
        512 => try verifyRs256Fixed(512, sig, signing_input, pk),
        else => return error.UnsupportedAlgorithm,
    }
}

fn verifyRs256Fixed(
    comptime modulus_len: usize,
    sig: []const u8,
    signing_input: []const u8,
    pk: rsa.PublicKey,
) JwtError!void {
    var sig_arr: [modulus_len]u8 = undefined;
    @memcpy(&sig_arr, sig[0..modulus_len]);
    rsa.PKCS1v1_5Signature.verify(modulus_len, sig_arr, signing_input, pk, Sha256) catch return error.InvalidSignature;
}

fn signRs256Fixed(
    comptime modulus_len: usize,
    signing_input: []const u8,
    modulus: []const u8,
    private_exponent: []const u8,
) JwtError![modulus_len]u8 {
    const pk = rsa.PublicKey.fromBytes(&[_]u8{ 0x01, 0x00, 0x01 }, modulus) catch return error.InvalidPrivateKey;
    const em = emsaPkcs1V15EncodeSha256(&.{signing_input}, modulus_len) catch return error.InvalidPrivateKey;
    const Fe = @TypeOf(pk.n).Fe;
    const m = Fe.fromBytes(pk.n, &em, .big) catch return error.InvalidPrivateKey;
    const sig_fe = pk.n.powWithEncodedExponent(m, private_exponent, .big) catch return error.InvalidPrivateKey;
    var sig: [modulus_len]u8 = undefined;
    sig_fe.toBytes(&sig, .big) catch return error.InvalidPrivateKey;
    return sig;
}

fn emsaPkcs1V15EncodeSha256(msg: []const []const u8, comptime em_len: usize) ![em_len]u8 {
    comptime var em_index = em_len;
    var em: [em_len]u8 = undefined;

    var hasher: Sha256 = .init(.{});
    for (msg) |part| hasher.update(part);
    em_index -= Sha256.digest_length;
    hasher.final(em[em_index..]);

    const hash_der: []const u8 = &.{
        0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
        0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
        0x00, 0x04, 0x20,
    };
    em_index -= hash_der.len;
    @memcpy(em[em_index..][0..hash_der.len], hash_der);

    em_index -= 1;
    @memset(em[2..em_index], 0xff);
    em[em_index] = 0x00;
    em[1] = 0x01;
    em[0] = 0x00;
    return em;
}

fn trimLeadingZeroes(raw: []const u8) []const u8 {
    const offset = for (raw, 0..) |byte, i| {
        if (byte != 0) break i;
    } else raw.len;
    return raw[offset..];
}

fn parsePrivateKeyDer(der: []const u8) JwtError!struct { modulus: []const u8, private_exponent: []const u8 } {
    const Element = std.crypto.Certificate.der.Element;
    const seq = Element.parse(der, 0) catch return error.InvalidPrivateKey;
    if (seq.identifier.tag != .sequence) return error.InvalidPrivateKey;
    var elem = Element.parse(der, seq.slice.start) catch return error.InvalidPrivateKey; // version
    elem = Element.parse(der, elem.slice.end) catch return error.InvalidPrivateKey; // modulus
    if (elem.identifier.tag != .integer) return error.InvalidPrivateKey;
    const modulus = trimLeadingZeroes(der[elem.slice.start..elem.slice.end]);
    elem = Element.parse(der, elem.slice.end) catch return error.InvalidPrivateKey; // publicExponent
    elem = Element.parse(der, elem.slice.end) catch return error.InvalidPrivateKey; // privateExponent
    if (elem.identifier.tag != .integer) return error.InvalidPrivateKey;
    const private_exponent = trimLeadingZeroes(der[elem.slice.start..elem.slice.end]);
    return .{ .modulus = modulus, .private_exponent = private_exponent };
}

/// Decode PEM or accept raw DER; return owned PKCS#1 RSAPrivateKey DER.
fn loadRsaPrivateKeyDer(allocator: std.mem.Allocator, input: []const u8) JwtError![]u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (std.mem.indexOf(u8, trimmed, "-----BEGIN") != null) {
        const der = decodePemBody(allocator, trimmed) catch return error.InvalidPrivateKey;
        errdefer allocator.free(der);
        if (parsePrivateKeyDer(der)) |_| {
            return der;
        } else |_| {
            const inner = unwrapPkcs8PrivateKey(der) catch return error.InvalidPrivateKey;
            const owned = try allocator.dupe(u8, inner);
            allocator.free(der);
            return owned;
        }
    }
    if (parsePrivateKeyDer(trimmed)) |_| {
        return try allocator.dupe(u8, trimmed);
    } else |_| {
        const inner = unwrapPkcs8PrivateKey(trimmed) catch return error.InvalidPrivateKey;
        return try allocator.dupe(u8, inner);
    }
}

fn unwrapPkcs8PrivateKey(der_bytes: []const u8) JwtError![]const u8 {
    const Element = std.crypto.Certificate.der.Element;
    const top = Element.parse(der_bytes, 0) catch return error.InvalidPrivateKey;
    if (top.identifier.tag != .sequence) return error.InvalidPrivateKey;
    var elem = Element.parse(der_bytes, top.slice.start) catch return error.InvalidPrivateKey; // version
    elem = Element.parse(der_bytes, elem.slice.end) catch return error.InvalidPrivateKey; // algorithm
    elem = Element.parse(der_bytes, elem.slice.end) catch return error.InvalidPrivateKey; // privateKey
    if (elem.identifier.tag != .octetstring) return error.InvalidPrivateKey;
    return der_bytes[elem.slice.start..elem.slice.end];
}

/// Decode PEM or accept raw DER; return owned PKCS#1 RSAPublicKey DER.
fn loadRsaPublicKeyDer(allocator: std.mem.Allocator, input: []const u8) JwtError![]u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (std.mem.indexOf(u8, trimmed, "-----BEGIN") != null) {
        const der = decodePemBody(allocator, trimmed) catch return error.InvalidPublicKey;
        errdefer allocator.free(der);
        if (rsa.PublicKey.parseDer(der)) |_| {
            return der;
        } else |_| {
            const inner = unwrapSpki(der) catch {
                return error.InvalidPublicKey;
            };
            const owned = try allocator.dupe(u8, inner);
            allocator.free(der);
            return owned;
        }
    }
    return try allocator.dupe(u8, trimmed);
}

fn decodePemBody(allocator: std.mem.Allocator, pem: []const u8) ![]u8 {
    var b64 = std.ArrayList(u8).empty;
    defer b64.deinit(allocator);
    var lines = std.mem.splitScalar(u8, pem, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "-----")) continue;
        try b64.appendSlice(allocator, line);
    }
    const dec = std.base64.standard.Decoder;
    const len = try dec.calcSizeForSlice(b64.items);
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    try dec.decode(out, b64.items);
    return out;
}

fn unwrapSpki(der_bytes: []const u8) ![]const u8 {
    const Element = std.crypto.Certificate.der.Element;
    const top = try Element.parse(der_bytes, 0);
    if (top.identifier.tag != .sequence) return error.InvalidPublicKey;
    const alg = try Element.parse(der_bytes, top.slice.start);
    const bitstr = try Element.parse(der_bytes, alg.slice.end);
    if (bitstr.identifier.tag != .bitstring) return error.InvalidPublicKey;
    const content = der_bytes[bitstr.slice.start..bitstr.slice.end];
    if (content.len < 2) return error.InvalidPublicKey;
    // First byte = unused bits; remainder is RSAPublicKey.
    return content[1..];
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

test "jwt: RS256 sign and verify roundtrip" {
    const allocator = std.testing.allocator;
    const priv_der = @embedFile("testdata_rs256_priv.der");
    const pub_pem = @embedFile("testdata_rs256_sign_pub.pem");
    const now: i64 = 1_700_000_000;

    const token = try signRs256(allocator, priv_der, .{
        .sub = "bob",
        .exp = now + 3600,
        .iat = now,
        .role = "user",
    });
    defer allocator.free(token);

    const claims = try verifyRs256(allocator, pub_pem, token, now, .{});
    defer freeClaims(allocator, claims);
    try std.testing.expectEqualStrings("bob", claims.sub);
    try std.testing.expectEqualStrings("user", claims.role.?);
}

test "jwt: RS256 verify with PKCS#1 DER and SPKI PEM" {
    const allocator = std.testing.allocator;
    const token = @embedFile("testdata_rs256.jwt");
    const der = @embedFile("testdata_rs256_rsapub.der");
    const pem = @embedFile("testdata_rs256_pub.pem");
    const now: i64 = 1_700_000_000; // before exp 4102444800

    const claims_der = try verifyRs256(allocator, der, std.mem.trim(u8, token, " \n\r\t"), now, .{});
    defer freeClaims(allocator, claims_der);
    try std.testing.expectEqualStrings("alice", claims_der.sub);

    const claims_pem = try verifyRs256(allocator, pem, std.mem.trim(u8, token, " \n\r\t"), now, .{});
    defer freeClaims(allocator, claims_pem);
    try std.testing.expectEqualStrings("alice", claims_pem.sub);

    try std.testing.expectError(
        error.UnsupportedAlgorithm,
        verify(allocator, "unused", std.mem.trim(u8, token, " \n\r\t"), now),
    );
}
