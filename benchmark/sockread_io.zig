//! Micro-benchmark: sockread vs shared Threaded Io reads, and HttpClient
//! dedicated-Io costs.
//!
//! Run: `zig build run-sockread-bench`
//!
//! What this measures (ReleaseFast):
//!   1. **threaded_lifecycle** — `Io.Threaded.init` + `io()` + `deinit` per
//!      iteration (paid once per `HttpClient.init`, not per request).
//!   2. **warm_read_sockread** — peer already wrote bytes; `sockread.readSome`.
//!   3. **warm_read_io** — same socketpair, `stream.read(io, …)` via Threaded.
//!   4. **local_http_reused_io** — loopback GET via one `HttpClient` (long-lived
//!      dedicated Io + reused `std.http.Client` / connection pool).
//!
//! Honest notes:
//!   - (2)/(3) are syscall micro-benches; real hang was correctness, not ns.
//!   - (4) should NOT include per-request Threaded init after HttpClient reuse.

const std = @import("std");
const zfinal = @import("zfinal");

const ITER_LIFECYCLE: usize = 2_000;
const ITER_WARM_READ: usize = 50_000;
const ITER_HTTP: usize = 200;

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @intCast(@as(i128, ts.sec) * std.time.ns_per_s + ts.nsec);
}

fn report(name: []const u8, iters: usize, elapsed_ns: u64) void {
    const ns_per = if (iters == 0) 0 else elapsed_ns / iters;
    const per_sec = if (elapsed_ns == 0) 0 else (@as(u64, @intCast(iters)) * std.time.ns_per_s) / elapsed_ns;
    std.debug.print("  {s:<28}  {d:>8} iters  {d:>10} ns total  {d:>8} ns/op  ~{d} ops/s\n", .{
        name,
        iters,
        elapsed_ns,
        ns_per,
        per_sec,
    });
}

fn benchThreadedLifecycle(allocator: std.mem.Allocator) void {
    var i: usize = 0;
    // Warmup
    while (i < 50) : (i += 1) {
        var threaded = std.Io.Threaded.init(allocator, .{});
        _ = threaded.io();
        threaded.deinit();
    }

    i = 0;
    const t0 = nowNs();
    while (i < ITER_LIFECYCLE) : (i += 1) {
        var threaded = std.Io.Threaded.init(allocator, .{});
        _ = threaded.io();
        threaded.deinit();
    }
    report("threaded_lifecycle", ITER_LIFECYCLE, nowNs() - t0);
}

fn makeSocketpair() ![2]std.posix.socket_t {
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SocketPairFailed,
    }
    return fds;
}

fn streamFromFd(fd: std.posix.socket_t) std.Io.net.Stream {
    return .{ .socket = .{ .handle = fd, .address = undefined } };
}

fn writeAllFd(fd: std.posix.socket_t, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const rc = std.posix.system.write(fd, bytes[sent..].ptr, bytes.len - sent);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.WriteZero;
                sent += n;
            },
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

fn benchWarmReadSockread() !void {
    const fds = try makeSocketpair();
    defer {
        _ = std.posix.system.close(fds[0]);
        _ = std.posix.system.close(fds[1]);
    }
    const reader = streamFromFd(fds[0]);
    const writer_fd = fds[1];

    const payload = "0123456789abcdef";
    var buf: [64]u8 = undefined;

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        _ = try writeAllFd(writer_fd, payload);
        _ = try zfinal.sockread.readSome(reader, &buf);
    }

    i = 0;
    const t0 = nowNs();
    while (i < ITER_WARM_READ) : (i += 1) {
        try writeAllFd(writer_fd, payload);
        const n = try zfinal.sockread.readSome(reader, &buf);
        if (n != payload.len) return error.UnexpectedReadLen;
    }
    report("warm_read_sockread", ITER_WARM_READ, nowNs() - t0);
}

fn benchWarmReadIo(allocator: std.mem.Allocator) !void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const fds = try makeSocketpair();
    defer {
        _ = std.posix.system.close(fds[0]);
        _ = std.posix.system.close(fds[1]);
    }
    const reader = streamFromFd(fds[0]);
    const writer_fd = fds[1];

    const payload = "0123456789abcdef";
    var buf: [64]u8 = undefined;

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try writeAllFd(writer_fd, payload);
        _ = try reader.read(io, data: {
            var d: [1][]u8 = .{&buf};
            break :data &d;
        });
    }

    i = 0;
    const t0 = nowNs();
    while (i < ITER_WARM_READ) : (i += 1) {
        try writeAllFd(writer_fd, payload);
        const n = try reader.read(io, data: {
            var d: [1][]u8 = .{&buf};
            break :data &d;
        });
        if (n != payload.len) return error.UnexpectedReadLen;
    }
    report("warm_read_io_net_read", ITER_WARM_READ, nowNs() - t0);
}

const HttpBenchState = struct {
    port: u16,
    ready: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),
};

fn httpServerThread(state: *HttpBenchState) void {
    const allocator = std.heap.page_allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Fixed port avoids Zig 0.17 getsockname API churn for this micro-bench.
    const port: u16 = 18765;
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return;
    var listener = addr.listen(io, .{ .reuse_address = true }) catch return;
    defer listener.deinit(io);

    state.port = port;
    state.ready.store(true, .release);

    const body = "ok";
    var resp_buf: [256]u8 = undefined;
    const resp = std.fmt.bufPrint(&resp_buf, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch return;

    while (!state.stop.load(.acquire)) {
        const conn = listener.accept(io) catch {
            if (state.stop.load(.acquire)) break;
            continue;
        };
        defer conn.close(io);

        var rbuf: [1024]u8 = undefined;
        _ = zfinal.sockread.readSomeTimeout(conn, &rbuf, 500) catch {};
        var wbuf: [256]u8 = undefined;
        var w = conn.writer(io, &wbuf);
        w.interface.writeAll(resp) catch {};
        w.interface.flush() catch {};
    }
}

fn benchLocalHttpDedicatedIo(allocator: std.mem.Allocator) !void {
    var state = HttpBenchState{ .port = 0 };
    const thr = try std.Thread.spawn(.{}, httpServerThread, .{&state});
    defer {
        state.stop.store(true, .release);
        // Unblock accept with a throwaway connect if still listening.
        if (state.port != 0) {
            var t = std.Io.Threaded.init(allocator, .{});
            defer t.deinit();
            const io = t.io();
            if (std.Io.net.IpAddress.parseIp4("127.0.0.1", state.port)) |addr| {
                if (addr.connect(io, .{ .mode = .stream })) |c| {
                    c.close(io);
                } else |_| {}
            } else |_| {}
        }
        thr.join();
    }

    const deadline = nowNs() + 3 * std.time.ns_per_s;
    while (!state.ready.load(.acquire)) {
        if (nowNs() > deadline) return error.ServerNotReady;
        // Busy-ish wait; avoid Zig 0.17 Thread.sleep removal.
        var spin: usize = 0;
        while (spin < 50_000) : (spin += 1) {
            std.mem.doNotOptimizeAway(spin);
        }
    }

    var url_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{state.port});

    var client = try zfinal.HttpClient.init(allocator, base);
    defer client.deinit();

    // Warmup
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var resp = try client.get("/");
        defer resp.deinit();
        if (resp.status != 200) return error.UnexpectedStatus;
    }

    i = 0;
    const t0 = nowNs();
    while (i < ITER_HTTP) : (i += 1) {
        var resp = try client.get("/");
        defer resp.deinit();
        if (resp.status != 200) return error.UnexpectedStatus;
    }
    report("local_http_reused_io", ITER_HTTP, nowNs() - t0);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\nsockread / HttpClient micro-bench (ReleaseFast)\n", .{});
    std.debug.print("────────────────────────────────────────────────────────────\n", .{});

    benchThreadedLifecycle(allocator);
    try benchWarmReadSockread();
    try benchWarmReadIo(allocator);
    try benchLocalHttpDedicatedIo(allocator);

    std.debug.print("────────────────────────────────────────────────────────────\n", .{});
    std.debug.print("Interpret: compare warm_read_*; threaded_lifecycle is paid\n", .{});
    std.debug.print("once per HttpClient.init; local_http_reused_io amortizes it.\n\n", .{});
}
