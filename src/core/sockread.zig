//! Raw socket I/O that bypasses `std.Io`'s `net_read` path.
//!
//! With Threaded Io shared across threads (accept + worker fibers + client),
//! io-based socket reads can block forever even when data is already in the
//! kernel buffer (reproduced on macOS: poll readable / MSG_PEEK show bytes,
//! `readv` still hangs). Writes and connects are unaffected.
//!
//! std.Io sockets are blocking: a bare `posix.read` already waits for data
//! (EOF = 0). Unlimited-wait helpers therefore do **not** poll — that would
//! double syscalls. Timed waits keep `poll` (Server idle timeout, Redis
//! deadline). For many small protocol reads (WebSocket frames), use
//! `BufReader` so one refill serves header/mask/payload.

const std = @import("std");

/// Read once into `buf` (blocking). Returns bytes read; 0 means peer closed.
pub fn readSome(stream: std.Io.net.Stream, buf: []u8) !usize {
    return std.posix.read(stream.socket.handle, buf) catch return error.ConnectionError;
}

/// Like `readSome`, but `timeout_ms` caps how long `poll` waits.
/// `-1` = wait forever (blocking `read`, no poll); `0` = try once / poll 0.
/// Returns `error.Timeout` when the poll deadline elapses with no data.
///
/// Fast path: `MSG.DONTWAIT` when bytes may already be buffered, then poll.
pub fn readSomeTimeout(stream: std.Io.net.Stream, buf: []u8, timeout_ms: i32) !usize {
    const fd = stream.socket.handle;

    if (timeout_ms < 0) {
        return readSome(stream, buf);
    }

    if (tryRecvDontWait(fd, buf)) |n| return n;

    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&fds, timeout_ms) catch return error.ConnectionError;
    if (ready == 0) return error.Timeout;
    if ((fds[0].revents & std.posix.POLL.IN) == 0) {
        if ((fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) return 0;
        return error.ConnectionError;
    }
    return std.posix.read(fd, buf) catch return error.ConnectionError;
}

fn tryRecvDontWait(fd: std.posix.socket_t, buf: []u8) ?usize {
    const rc = std.posix.system.recv(fd, buf.ptr, buf.len, std.posix.MSG.DONTWAIT);
    switch (std.posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .AGAIN => return null,
        .INTR => return tryRecvDontWait(fd, buf),
        else => return null,
    }
}

/// Read exactly `buf.len` bytes (blocks until complete, error, or EOF).
pub fn readFull(stream: std.Io.net.Stream, buf: []u8) !void {
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = try readSome(stream, buf[filled..]);
        if (n == 0) return error.ConnectionClosed;
        filled += n;
    }
}

/// Buffered socket reader: collapses many small reads into one larger syscall.
/// `buf` is caller-owned (e.g. 4–8KB) and reused across calls.
/// Do not mix with raw `readSome`/`readFull` on the same stream while buffered
/// bytes remain (they would be skipped).
pub const BufReader = struct {
    stream: std.Io.net.Stream,
    buf: []u8,
    start: usize = 0,
    end: usize = 0,

    pub fn init(stream: std.Io.net.Stream, buf: []u8) BufReader {
        return .{ .stream = stream, .buf = buf };
    }

    /// Read exactly `out.len` bytes from cache, refilling with one larger read.
    pub fn readFull(self: *BufReader, out: []u8) !void {
        var filled: usize = 0;
        while (filled < out.len) {
            if (self.start < self.end) {
                const n = @min(self.end - self.start, out.len - filled);
                @memcpy(out[filled..][0..n], self.buf[self.start..][0..n]);
                self.start += n;
                filled += n;
            } else {
                const n = try readSome(self.stream, self.buf);
                if (n == 0) return error.ConnectionClosed;
                self.start = 0;
                self.end = n;
            }
        }
    }
};

/// `std.Io.Reader` backed by timed sockread — underlay for `http.Server`, TLS
/// `Client`, etc. (`timeout_ms == 0` = wait forever).
pub const TimedIoReader = struct {
    interface: std.Io.Reader,
    stream: std.Io.net.Stream,
    timeout_ms: u64,
    err: ?anyerror = null,

    const max_iovecs_len = 8;

    pub fn init(stream: std.Io.net.Stream, buffer: []u8, timeout_ms: u64) TimedIoReader {
        return .{
            .interface = .{
                .vtable = &.{
                    .stream = streamImpl,
                    .readVec = readVec,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .stream = stream,
            .timeout_ms = timeout_ms,
        };
    }

    fn streamImpl(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn readVec(io_r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const r: *TimedIoReader = @alignCast(@fieldParentPtr("interface", io_r));
        var iovecs_buffer: [max_iovecs_len][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs_buffer, data);
        const dest = iovecs_buffer[0..dest_n];
        std.debug.assert(dest[0].len > 0);

        const timeout: i32 = if (r.timeout_ms == 0)
            -1
        else
            @intCast(@min(r.timeout_ms, std.math.maxInt(i32)));

        const n = readSomeTimeout(r.stream, dest[0], timeout) catch |err| {
            r.err = err;
            return error.ReadFailed;
        };
        if (n == 0) return error.EndOfStream;
        if (n > data_size) {
            r.interface.end += n - data_size;
            return data_size;
        }
        return n;
    }
};

/// @deprecated Use `TimedIoReader`.
pub const Reader = TimedIoReader;

test "readSome returns EOF on closed socketpair" {
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    _ = std.posix.system.close(fds[1]);
    const stream = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    defer stream.close(std.testing.io);
    var buf: [16]u8 = undefined;
    const n = try readSome(stream, &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "readSomeTimeout returns Timeout when nothing ready" {
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    defer {
        _ = std.posix.system.close(fds[0]);
        _ = std.posix.system.close(fds[1]);
    }
    const stream = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    var buf: [16]u8 = undefined;
    try std.testing.expectError(error.Timeout, readSomeTimeout(stream, &buf, 0));
}

test "BufReader serves many small reads from one refill" {
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    const peer = std.Io.net.Stream{ .socket = .{ .handle = fds[1], .address = undefined } };
    const stream = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    defer peer.close(std.testing.io);
    defer stream.close(std.testing.io);
    _ = std.posix.system.write(fds[1], "hello", 5);

    var rbuf: [64]u8 = undefined;
    var reader = BufReader.init(stream, &rbuf);
    var out: [5]u8 = undefined;
    try reader.readFull(out[0..2]);
    try reader.readFull(out[2..4]);
    try reader.readFull(out[4..5]);
    try std.testing.expectEqualStrings("hello", &out);
}
