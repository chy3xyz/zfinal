const std = @import("std");
const zfinal = @import("../core/zfinal.zig");
const Plugin = @import("plugin.zig").Plugin;
const HashKit = @import("../kit/hash_kit.zig").HashKit;

/// DID Document Structure
pub const DidDocument = struct {
    context: []const []const u8 = &[_][]const u8{"https://www.w3.org/ns/did/v1"},
    id: []const u8,
    verificationMethod: []const VerificationMethod,
    authentication: []const []const u8,
};

pub const VerificationMethod = struct {
    id: []const u8,
    type: []const u8,
    controller: []const u8,
    publicKeyMultibase: []const u8,
};

/// DID Plugin Implementation
pub const DidPlugin = struct {
    allocator: std.mem.Allocator,
    key_pair: std.crypto.sign.Ed25519.KeyPair,
    did: []const u8,

    pub fn init(allocator: std.mem.Allocator) !DidPlugin {
        var seed: [std.crypto.sign.Ed25519.KeyPair.seed_length]u8 = undefined;
        std.crypto.random.bytes(&seed);
        const key_pair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
        // Generate DID from public key (simplified did:key method)
        // In reality, did:key uses multicodec/multibase
        const pub_key_bytes = key_pair.public_key.bytes;
        const did_id = try std.fmt.allocPrint(allocator, "did:key:z{s}", .{std.fmt.fmtSliceHexLower(&pub_key_bytes)});

        return DidPlugin{
            .allocator = allocator,
            .key_pair = key_pair,
            .did = did_id,
        };
    }

    pub fn deinit(self: *DidPlugin) void {
        self.allocator.free(self.did);
    }

    /// Implement Plugin interface
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
        std.debug.print("Starting DID Plugin...\n", .{});
        std.debug.print("Initialized Identity: {s}\n", .{self.did});
    }

    fn stop(ctx: *anyopaque) !void {
        _ = ctx;
        std.debug.print("DID Plugin stopped.\n", .{});
    }

    /// Sign data
    pub fn sign(self: *DidPlugin, data: []const u8) ![]const u8 {
        const signature = try self.key_pair.sign(data, null);
        return try std.fmt.allocPrint(self.allocator, "{s}", .{std.fmt.fmtSliceHexLower(&signature.toBytes())});
    }

    /// Verify signature
    pub fn verify(self: *DidPlugin, data: []const u8, signature_hex: []const u8, public_key_hex: []const u8) !bool {
        _ = self;
        var sig_bytes: [64]u8 = undefined;
        _ = try std.fmt.hexToBytes(&sig_bytes, signature_hex);
        const signature = std.crypto.sign.Ed25519.Signature.fromBytes(sig_bytes);

        var pub_bytes: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&pub_bytes, public_key_hex);
        const public_key = try std.crypto.sign.Ed25519.PublicKey.fromBytes(pub_bytes);

        signature.verify(data, public_key) catch return false;
        return true;
    }

    /// Resolve DID (Mock implementation)
    pub fn resolve(self: *DidPlugin, did: []const u8) !DidDocument {
        // In a real implementation, this would look up the DID on a ledger or resolver
        if (std.mem.eql(u8, did, self.did)) {
            // Return our own document
            const pub_key_bytes = self.key_pair.public_key.bytes;
            const pub_key_hex = try std.fmt.allocPrint(self.allocator, "{s}", .{std.fmt.fmtSliceHexLower(&pub_key_bytes)});

            // Construct VerificationMethod (simplified)
            // Note: This leaks memory in this simple example, needs proper arena or management
            const vm = VerificationMethod{
                .id = try std.fmt.allocPrint(self.allocator, "{s}#key-1", .{did}),
                .type = "Ed25519VerificationKey2020",
                .controller = did,
                .publicKeyMultibase = pub_key_hex,
            };

            return DidDocument{
                .id = did,
                .verificationMethod = &[_]VerificationMethod{vm},
                .authentication = &[_][]const u8{vm.id},
            };
        }
        return error.DidNotFound;
    }
};
