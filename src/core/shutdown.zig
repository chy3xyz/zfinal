const std = @import("std");

/// Global shutdown flag. Set by signal handler, checked by server loops.
pub var shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Register signal handlers for graceful shutdown (SIGTERM, SIGINT).
/// After calling this, check `isShuttingDown()` in your accept/request loop.
pub fn registerHandlers() void {
    var act = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

fn handleSignal(_: std.posix.SIG) callconv(.c) void {
    shutting_down.store(true, .monotonic);
}

pub fn isShuttingDown() bool {
    return shutting_down.load(.monotonic);
}

/// Ask the server to shut down, as if SIGTERM had arrived.
///
/// The server needs this for the paths it has to stop on its own: a fatal
/// accept error, or the drain deadline running out. Cancelling the task
/// group is not an option there — the group is already being awaited by
/// `Server.start`, and Zig's group can only be awaited *or* cancelled,
/// never both.
pub fn requestShutdown() void {
    shutting_down.store(true, .monotonic);
}
