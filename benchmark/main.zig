const std = @import("std");
const zfinal = @import("zfinal");

/// Benchmark Configuration
const Config = struct {
    url: []const u8 = "http://127.0.0.1:8080/",
    concurrency: usize = 50,
    requests: usize = 10000,
    method: std.http.Method = .GET,
};

const Stats = struct {
    requests: usize = 0,
    failures: usize = 0,
    total_duration_ns: u64 = 0,
    mutex: std.Thread.Mutex = .{},

    pub fn add(self: *Stats, duration_ns: u64, failed: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.requests += 1;
        if (failed) self.failures += 1;
        self.total_duration_ns += duration_ns;
    }
};

fn worker(allocator: std.mem.Allocator, config: Config, stats: *Stats, wg: *std.Thread.WaitGroup) !void {
    defer wg.finish();

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const requests_per_worker = config.requests / config.concurrency;

    var buf: [4096]u8 = undefined;
    const uri = try std.Uri.parse(config.url);

    for (0..requests_per_worker) |_| {
        const start = std.time.nanoTimestamp();
        var failed = false;

        var req = client.open(config.method, uri, .{
            .server_header_buffer = &buf,
        }) catch {
            failed = true;
            stats.add(0, true);
            continue;
        };
        defer req.deinit();

        req.send() catch {
            failed = true;
            stats.add(0, true);
            continue;
        };

        req.wait() catch {
            failed = true;
            stats.add(0, true);
            continue;
        };

        if (req.response.status != .ok) {
            failed = true;
        }

        const end = std.time.nanoTimestamp();
        stats.add(@intCast(end - start), failed);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config = Config{};
    if (args.len > 1) config.url = args[1];
    if (args.len > 2) config.requests = try std.fmt.parseInt(usize, args[2], 10);
    if (args.len > 3) config.concurrency = try std.fmt.parseInt(usize, args[3], 10);

    std.debug.print("\n🚀 Starting Zig Benchmark\n", .{});
    std.debug.print("URL:         {s}\n", .{config.url});
    std.debug.print("Requests:    {d}\n", .{config.requests});
    std.debug.print("Concurrency: {d}\n", .{config.concurrency});
    std.debug.print("--------------------------------------------------\n", .{});

    var stats = Stats{};
    var wg = std.Thread.WaitGroup{};

    const start_time = std.time.nanoTimestamp();

    for (0..config.concurrency) |_| {
        wg.start();
        const thread = try std.Thread.spawn(.{}, worker, .{ allocator, config, &stats, &wg });
        thread.detach();
    }

    wg.wait();

    const end_time = std.time.nanoTimestamp();
    const total_time_ns = end_time - start_time;
    const total_time_s = @as(f64, @floatFromInt(total_time_ns)) / 1_000_000_000.0;
    const rps = @as(f64, @floatFromInt(stats.requests)) / total_time_s;
    const avg_latency_ms = (@as(f64, @floatFromInt(stats.total_duration_ns)) / @as(f64, @floatFromInt(stats.requests))) / 1_000_000.0;

    std.debug.print("\n📊 Results:\n", .{});
    std.debug.print("Total Time:    {d:.2} s\n", .{total_time_s});
    std.debug.print("Total Requests: {d}\n", .{stats.requests});
    std.debug.print("Failed:        {d}\n", .{stats.failures});
    std.debug.print("RPS:           {d:.2} req/s\n", .{rps});
    std.debug.print("Avg Latency:   {d:.2} ms\n", .{avg_latency_ms});
    std.debug.print("--------------------------------------------------\n", .{});
}
