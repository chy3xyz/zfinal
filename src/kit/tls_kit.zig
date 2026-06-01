const std = @import("std");
const builtin = @import("builtin");
const io_instance = @import("../io_instance.zig");

/// OS-specific TLS CA bundle paths. Used by `std.http.Client` for certificate verification.
///
/// Call `defaultBundlePath()` to get the system CA bundle path for the current platform.
/// Returns null if no known bundle path exists for this platform.
pub const TlsKit = struct {
    /// Common CA bundle paths for each OS, ordered by preference.
    const ca_bundle_paths = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => [_][]const u8{
            "/etc/ssl/cert.pem",
            "/usr/local/etc/ca-certificates/cert.pem",
            "/opt/homebrew/etc/ca-certificates/cert.pem",
        },
        .linux => [_][]const u8{
            "/etc/ssl/certs/ca-certificates.crt",
            "/etc/pki/tls/certs/ca-bundle.crt",
            "/etc/ssl/ca-bundle.pem",
            "/etc/pki/tls/cacert.pem",
            "/etc/ssl/cert.pem",
        },
        .freebsd, .netbsd, .dragonfly => [_][]const u8{
            "/usr/local/share/certs/ca-root-nss.crt",
            "/etc/ssl/cert.pem",
        },
        .openbsd => [_][]const u8{
            "/etc/ssl/cert.pem",
        },
        else => [_][]const u8{},
    };

    /// Returns the path to the first found system CA bundle, or null.
    pub fn defaultBundlePath() ?[]const u8 {
        for (ca_bundle_paths) |path| {
            const f = std.Io.Dir.openFileAbsolute(io_instance.io, path, .{}) catch continue;
            f.close(io_instance.io);
            return path;
        }
        return null;
    }

    /// Load the system CA bundle into a buffer. Caller owns memory.
    /// Returns null if no bundle found.
    pub fn loadBundle(allocator: std.mem.Allocator, max_size: usize) !?[]u8 {
        const path = defaultBundlePath() orelse return null;
        const file = try std.Io.Dir.openFileAbsolute(io_instance.io, path, .{});
        defer file.close(io_instance.io);
        const stat = try file.stat(io_instance.io);
        if (stat.size > max_size) return error.BundleTooLarge;
        const buf = try allocator.alloc(u8, @intCast(stat.size));
        _ = try file.reader(io_instance.io, buf).interface.readAll(buf);
        return buf;
    }

    /// Read the CA bundle into an owned slice.
    /// Returns null if no bundle found.
    pub fn readBundle(allocator: std.mem.Allocator) !?[]u8 {
        return loadBundle(allocator, 1024 * 1024); // 1MB max
    }
};

test "TlsKit default bundle path known" {
    // Verify the function compiles and returns a valid type — actual path
    // depends on the OS running the test.
    const path = TlsKit.defaultBundlePath();
    _ = path;
}

test "TlsKit macOS path" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const path = TlsKit.defaultBundlePath();
    try std.testing.expect(path != null);
}
