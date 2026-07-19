const std = @import("std");
const io_instance = @import("../io_instance.zig");
const Plugin = @import("plugin.zig").Plugin;

/// DID Document (W3C-inspired). Owned strings live in `arena` / caller frees via `deinit`.
pub const DidDocument = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    verification_method_id: []const u8,
    public_key_hex: []const u8,
    /// Authentication references the verification method id.
    authentication: []const u8,

    pub fn deinit(self: *DidDocument) void {
        self.allocator.free(self.id);
        self.allocator.free(self.verification_method_id);
        self.allocator.free(self.public_key_hex);
        // authentication aliases verification_method_id — already freed
    }
};

/// Local `did:key`-style identity with Ed25519 sign/verify.
/// Network DID resolution is out of scope; `resolve` only returns this node's document.
pub const DidPlugin = struct {
    allocator: std.mem.Allocator,
    key_pair: std.crypto.sign.Ed25519.KeyPair,
    did: []const u8,

    pub fn init(allocator: std.mem.Allocator) !DidPlugin {
        var seed: [std.crypto.sign.Ed25519.KeyPair.seed_length]u8 = undefined;
        io_instance.io.random(&seed);
        const key_pair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
        const pub_key_bytes = key_pair.public_key.bytes;
        const hex_bytes = std.fmt.bytesToHex(&pub_key_bytes, .lower);
        const did_id = try std.fmt.allocPrint(allocator, "did:key:z{s}", .{hex_bytes});

        return .{
            .allocator = allocator,
            .key_pair = key_pair,
            .did = did_id,
        };
    }

    pub fn deinit(self: *DidPlugin) void {
        self.allocator.free(self.did);
    }

    pub fn plugin(self: *DidPlugin) Plugin {
        return Plugin{
            .name = "DID",
            .vtable = &.{
                .start = start,
                .stop = stop,
            },
            .context = self,
        };
    }

    fn start(ctx: *anyopaque) !void {
        const self: *DidPlugin = @ptrCast(@alignCast(ctx));
        std.log.info("DID plugin ready: {s}", .{self.did});
    }

    fn stop(_: *anyopaque) !void {}

    /// Sign data; returns owned hex signature (caller frees).
    pub fn sign(self: *DidPlugin, data: []const u8) ![]const u8 {
        const signature = try self.key_pair.sign(data, null);
        const hex_sig = std.fmt.bytesToHex(&signature.toBytes(), .lower);
        return try self.allocator.dupe(u8, &hex_sig);
    }

    /// Verify hex signature against a hex public key.
    pub fn verify(_: *DidPlugin, data: []const u8, signature_hex: []const u8, public_key_hex: []const u8) !bool {
        var sig_bytes: [64]u8 = undefined;
        _ = try std.fmt.hexToBytes(&sig_bytes, signature_hex);
        const signature = std.crypto.sign.Ed25519.Signature.fromBytes(sig_bytes);

        var pub_bytes: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&pub_bytes, public_key_hex);
        const public_key = try std.crypto.sign.Ed25519.PublicKey.fromBytes(pub_bytes);

        signature.verify(data, public_key) catch return false;
        return true;
    }

    /// Public key of this identity as lowercase hex (owned — caller frees).
    pub fn publicKeyHex(self: *DidPlugin) ![]const u8 {
        const bytes = self.key_pair.public_key.bytes;
        const hex = std.fmt.bytesToHex(&bytes, .lower);
        return try self.allocator.dupe(u8, &hex);
    }

    /// Resolve only the local DID. Caller must `doc.deinit()`.
    pub fn resolve(self: *DidPlugin, did: []const u8) !DidDocument {
        if (!std.mem.eql(u8, did, self.did)) return error.DidNotFound;

        const id = try self.allocator.dupe(u8, did);
        errdefer self.allocator.free(id);
        const vm_id = try std.fmt.allocPrint(self.allocator, "{s}#key-1", .{did});
        errdefer self.allocator.free(vm_id);
        const pub_hex = try self.publicKeyHex();
        errdefer self.allocator.free(pub_hex);

        return .{
            .allocator = self.allocator,
            .id = id,
            .verification_method_id = vm_id,
            .public_key_hex = pub_hex,
            .authentication = vm_id,
        };
    }
};

test "did: sign and verify roundtrip" {
    const a = std.testing.allocator;
    var plugin = try DidPlugin.init(a);
    defer plugin.deinit();

    const sig = try plugin.sign("hello");
    defer a.free(sig);
    const pub_hex = try plugin.publicKeyHex();
    defer a.free(pub_hex);

    try std.testing.expect(try plugin.verify("hello", sig, pub_hex));
    try std.testing.expect(!try plugin.verify("other", sig, pub_hex));
}

test "did: resolve local document" {
    const a = std.testing.allocator;
    var plugin = try DidPlugin.init(a);
    defer plugin.deinit();

    var doc = try plugin.resolve(plugin.did);
    defer doc.deinit();
    try std.testing.expectEqualStrings(plugin.did, doc.id);
    try std.testing.expect(std.mem.endsWith(u8, doc.verification_method_id, "#key-1"));

    try std.testing.expectError(error.DidNotFound, plugin.resolve("did:key:zunknown"));
}
