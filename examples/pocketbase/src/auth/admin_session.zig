const std = @import("std");
const zfinal = @import("zfinal");

/// Server-side admin sessions for the PocketBase Lite example.
///
/// The cookie carries an unguessable opaque token; the server decides whether
/// it is a valid, unexpired session. This replaces the old literal
/// `admin_session="true"` cookie, which anyone could forge.
const Session = struct { expires_at: i64 };

const ttl_seconds: i64 = 24 * 60 * 60;

var store: std.StringHashMap(Session) = undefined;
var store_allocator: std.mem.Allocator = undefined;
var ready: bool = false;
var mutex: std.Io.Mutex = std.Io.Mutex.init;

pub fn init(allocator: std.mem.Allocator) void {
    store = std.StringHashMap(Session).init(allocator);
    store_allocator = allocator;
    ready = true;
}

fn now() i64 {
    return std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
}

/// Create a new admin session and return its token (allocated; kept alive by
/// the store, so callers must not free it).
pub fn create() ![]const u8 {
    var bytes: [32]u8 = undefined;
    zfinal.io_instance.io.random(&bytes);
    const token = try std.fmt.allocPrint(store_allocator, "{s}", .{std.fmt.bytesToHex(&bytes, .lower)});
    errdefer store_allocator.free(token);

    const io = zfinal.io_instance.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    try store.put(token, .{ .expires_at = now() + ttl_seconds });
    return token;
}

pub fn validate(token: []const u8) bool {
    if (!ready or token.len == 0) return false;
    const io = zfinal.io_instance.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const sess = store.get(token) orelse return false;
    if (sess.expires_at <= now()) {
        if (store.fetchRemove(token)) |kv| store_allocator.free(kv.key);
        return false;
    }
    return true;
}

pub fn destroy(token: []const u8) void {
    if (!ready or token.len == 0) return;
    const io = zfinal.io_instance.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (store.fetchRemove(token)) |kv| store_allocator.free(kv.key);
}

/// Read the admin cookie and verify it server-side.
pub fn check(ctx: *zfinal.Context) bool {
    const token = (ctx.getCookie("admin_session") catch return false) orelse return false;
    return validate(token);
}
