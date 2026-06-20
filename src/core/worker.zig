const std = @import("std");
const builtin = @import("builtin");

/// Raw POSIX thread — bypasses Zig 0.17 std.Thread.spawn.
///
/// Background: std.Thread.spawn on aarch64-macos has a TLS/errno
/// initialization issue that corrupts mysql_real_connect after the
/// first call (Lost connection at 'reading initial communication').
///
/// Use this module to spawn worker threads that need DB connections.
///
/// Pattern (user allocates the context, Worker spawns the thread):
///
///   const Context = struct {
///       config: zfinal.DBConfig,
///       fn run(raw: *anyopaque) callconv(.c) ?*anyopaque {
///           const self: *@This() = @ptrCast(@alignCast(raw));
///           var db = zfinal.DB.init(self.config, ...) catch return null;
///           // ... work ...
///           return null;
///       }
///   };
///
///   // Allocate on heap so the thread owns it.
///   const ctx = try allocator.create(Context);
///   ctx.* = .{ .config = myCfg };
///   const thread = try zfinal.Worker.spawn(Context.run, ctx);
///
///   // ... later ...
///   thread.join();
///   allocator.destroy(ctx);
///
pub const Thread = struct {
    handle: std.c.pthread_t,
    pub const EntryFn = *const fn (*anyopaque) callconv(.c) ?*anyopaque;

    /// Spawn a new OS thread. `entry` is the thread start routine,
    /// `arg` is passed as the void* argument.
    pub fn spawn(entry: EntryFn, arg: *anyopaque) !Thread {
        var handle: std.c.pthread_t = undefined;
        const rc = std.c.pthread_create(&handle, null, entry, arg);
        if (rc != .SUCCESS) return error.ThreadSpawnFailed;
        return Thread{ .handle = handle };
    }

    /// Wait for the thread to finish.
    pub fn join(self: *Thread) void {
        const rc = std.c.pthread_join(self.handle, null);
        if (rc != .SUCCESS) {
            std.debug.print("pthread_join failed: {t}\n", .{rc});
        }
    }

    /// Detach the thread (fire-and-forget).
    pub fn detach(self: *Thread) void {
        const rc = std.c.pthread_detach(self.handle);
        if (rc != .SUCCESS) {
            std.debug.print("pthread_detach failed: {t}\n", .{rc});
        }
    }
};

/// Higher-level: spawn using std.Thread.spawn when TLS is not an issue,
/// Thread.spawn (pthread_create) when on aarch64-macos.
pub fn spawnSafe(allocator: std.mem.Allocator, comptime entry: Thread.EntryFn, arg: *anyopaque) !std.Thread {
    if (builtin.os.tag == .macos and builtin.cpu.arch.isAARCH64()) {
        const pt = try Thread.spawn(entry, arg);
        return std.Thread{ .handle = pt.handle };
    }
    // On other platforms: wrap the C entry in a Zig-compatible closure
    const Box = struct {
        fn run(raw: *anyopaque) void {
            _ = entry(raw);
        }
    };
    return std.Thread.spawn(allocator, Box.run, arg);
}

test "worker: spawn + join roundtrip" {
    const Box = struct {
        done: bool,
        fn run(raw: *anyopaque) callconv(.c) ?*anyopaque {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.done = true;
            return null;
        }
    };
    const box = try std.testing.allocator.create(Box);
    defer std.testing.allocator.destroy(box);
    box.* = .{ .done = false };

    const t = try Thread.spawn(Box.run, box);
    t.join();
    try std.testing.expect(box.done);
}
