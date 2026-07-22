//! `zf bench` — HTTP load testing.
const std = @import("std");
const zf_shared = @import("zf_shared.zig");

// ─────────────────────────────────────────────────────────────────────────────
// BENCH — HTTP load testing
// ─────────────────────────────────────────────────────────────────────────────

const BenchResult = struct {
    latency_us: u64,
    status: u16,
    had_error: bool,
};

/// Fire N requests at URL with C concurrent workers. Print stats:
/// RPS, p50/p95/p99 latency, total time, error rate.
pub fn handleBench(allocator: std.mem.Allocator, url: []const u8, count: usize, concurrency: usize) !void {
    std.debug.print("\n⚡ ZFinal Bench — {s} requests with concurrency={d}\n", .{ url, concurrency });
    std.debug.print("════════════════════════════════════════════════════\n", .{});

    const parsed = parseUrl(url) orelse {
        std.debug.print("✗ Invalid URL. Expected: http://host:port/path\n", .{});
        return;
    };

    const results = try allocator.alloc(BenchResult, count);
    defer allocator.free(results);

    var completed: usize = 0;
    const start_ts = std.Io.Timestamp.now(zf_shared.io, .real);

    var worker_idx: usize = 0;
    while (worker_idx < concurrency) : (worker_idx += 1) {
        const worker = BenchWorker{
            .allocator = allocator,
            .host = parsed.host,
            .port = parsed.port,
            .path = parsed.path,
            .is_tls = parsed.is_tls,
            .start_index = worker_idx,
            .stride = concurrency,
            .total = count,
            .results = results,
            .completed = &completed,
            .io = zf_shared.io,
        };
        const handle = try std.Thread.spawn(.{ .stack_size = 1 * 1024 * 1024 }, runBenchWorker, .{worker});
        handle.join();
    }

    const end_ts = std.Io.Timestamp.now(zf_shared.io, .real);
    const elapsed_ns = end_ts.toNanoseconds() -% start_ts.toNanoseconds();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    try printBenchReport(allocator, results, elapsed_s);
}

const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
    is_tls: bool,
};

fn parseUrl(url: []const u8) ?ParsedUrl {
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return null;
    const is_tls = std.mem.startsWith(u8, url, "https://");
    const scheme_len: usize = if (is_tls) 8 else 7;
    var rest = url[scheme_len..];

    const slash_idx = std.mem.indexOf(u8, rest, "/") orelse rest.len;
    const host_port = rest[0..slash_idx];
    const path = if (slash_idx < rest.len) rest[slash_idx..] else "/";

    const colon_idx = std.mem.indexOf(u8, host_port, ":");
    const host = if (colon_idx) |i| host_port[0..i] else host_port;
    const port: u16 = if (colon_idx) |i| std.fmt.parseInt(u16, host_port[i + 1 ..], 10) catch 80 else 80;

    return .{
        .host = host,
        .port = port,
        .path = path,
        .is_tls = is_tls,
    };
}

const BenchWorker = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    path: []const u8,
    is_tls: bool,
    start_index: usize,
    stride: usize,
    total: usize,
    results: []BenchResult,
    completed: *usize,
    io: std.Io,
};

fn runBenchWorker(w: BenchWorker) void {
    _ = w.is_tls;
    var idx: usize = w.start_index;
    while (idx < w.total) : (idx += w.stride) {
        const start_ts = std.Io.Timestamp.now(w.io, .real);
        const result = benchRequest(w.allocator, w.host, w.port, w.path);
        const end_ts = std.Io.Timestamp.now(w.io, .real);
        const elapsed_us: u64 = @intCast(@divTrunc(end_ts.toNanoseconds() - start_ts.toNanoseconds(), 1000));
        w.results[idx] = .{
            .latency_us = elapsed_us,
            .status = result.status,
            .had_error = result.error_msg != null,
        };
        _ = @atomicRmw(usize, w.completed, .Add, 1, .seq_cst);
    }
}

const BenchRequestResult = struct {
    status: u16,
    error_msg: ?[]const u8,
};

fn benchRequest(allocator: std.mem.Allocator, host: []const u8, port: u16, path: []const u8) BenchRequestResult {
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = zf_shared.io,
    };
    defer client.deinit();
    const url_str = std.fmt.allocPrint(allocator, "http://{s}:{d}{s}", .{ host, port, path }) catch {
        return .{ .status = 0, .error_msg = "url alloc failed" };
    };
    defer allocator.free(url_str);
    const result = client.fetch(.{
        .location = .{ .url = url_str },
        .method = .GET,
    }) catch {
        return .{ .status = 0, .error_msg = "fetch failed" };
    };
    return .{ .status = @intFromEnum(result.status), .error_msg = null };
}

fn printBenchReport(allocator: std.mem.Allocator, results: []BenchResult, elapsed_s: f64) !void {
    var latencies: std.ArrayList(u64) = .empty;
    defer latencies.deinit(allocator);

    var errors: usize = 0;
    var status_hist: [10]usize = @splat(0);
    var min_us: u64 = std.math.maxInt(u64);
    var max_us: u64 = 0;
    var sum_us: u64 = 0;

    for (results) |r| {
        try latencies.append(allocator, r.latency_us);
        if (r.had_error) errors += 1;
        if (r.status > 0 and r.status < 1000) {
            status_hist[r.status / 100] += 1;
        }
        if (r.latency_us < min_us) min_us = r.latency_us;
        if (r.latency_us > max_us) max_us = r.latency_us;
        sum_us += r.latency_us;
    }
    std.mem.sort(u64, latencies.items, {}, std.sort.asc(u64));

    const total = results.len;
    const rps = @as(f64, @floatFromInt(total)) / elapsed_s;
    const avg_us: f64 = @as(f64, @floatFromInt(sum_us)) / @as(f64, @floatFromInt(total));
    const p50 = latencies.items[total * 50 / 100];
    const p95 = latencies.items[total * 95 / 100];
    const p99 = latencies.items[total * 99 / 100];

    std.debug.print("\nResults:\n", .{});
    std.debug.print("  Total requests:  {d}\n", .{total});
    std.debug.print("  Total time:      {d:.3}s\n", .{elapsed_s});
    std.debug.print("  Throughput:      {d:.1} req/s\n", .{rps});
    std.debug.print("  Errors:          {d} ({d:.2}%)\n", .{ errors, @as(f64, @floatFromInt(errors)) * 100.0 / @as(f64, @floatFromInt(total)) });

    std.debug.print("\nLatency:\n", .{});
    std.debug.print("  Min:   {d} µs\n", .{min_us});
    std.debug.print("  Avg:   {d:.0} µs\n", .{avg_us});
    std.debug.print("  p50:   {d} µs\n", .{p50});
    std.debug.print("  p95:   {d} µs\n", .{p95});
    std.debug.print("  p99:   {d} µs\n", .{p99});
    std.debug.print("  Max:   {d} µs\n", .{max_us});

    std.debug.print("\nStatus codes:\n", .{});
    for (status_hist, 1..) |count, code| {
        if (count > 0) {
            std.debug.print("  {d}xx: {d}\n", .{ code, count });
        }
    }
    std.debug.print("\n════════════════════════════════════════════════════\n", .{});
}
