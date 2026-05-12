const std = @import("std");

/// Global shutdown flag. Set by signal handler, checked by server loops.
pub var shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Register signal handlers for graceful shutdown (SIGTERM, SIGINT).
/// After calling this, check `isShuttingDown()` in your accept/request loop.
pub fn registerHandlers() void {
    var act = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

fn handleSignal(_: c_int) callconv(.c) void {
    shutting_down.store(true, .monotonic);
}

pub fn isShuttingDown() bool {
    return shutting_down.load(.monotonic);
}
